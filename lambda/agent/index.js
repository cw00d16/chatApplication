const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, PutCommand, QueryCommand, UpdateCommand } = require("@aws-sdk/lib-dynamodb");
const { SecretsManagerClient, GetSecretValueCommand } = require("@aws-sdk/client-secrets-manager");
const Anthropic = require("@anthropic-ai/sdk");
const { randomUUID } = require("crypto");
const { truncate, buildUserTurn, callClaude } = require("./respond");

const ddb = new DynamoDBClient({});
const db = DynamoDBDocumentClient.from(ddb);
const secretsClient = new SecretsManagerClient({});

const MESSAGES_TABLE = process.env.MESSAGES_TABLE;
const RATE_LIMIT_TABLE = process.env.AGENT_RATE_LIMIT_TABLE;
const ANTHROPIC_SECRET_ARN = process.env.ANTHROPIC_SECRET_ARN;
// Haiku 4.5: same input/output shape as Opus, at roughly a fifth of the
// per-token price on both sides — a big lever on its own, before caching
// or dropping tools. Override with the AGENT_MODEL env var if a different
// model is ever needed (not currently set anywhere in Terraform).
const MODEL = process.env.AGENT_MODEL || "claude-haiku-4-5";

// --- Guardrail knobs (all overridable via env var without a code change) ---
const RATE_LIMIT_PER_MINUTE = Number(process.env.AGENT_RATE_LIMIT_PER_MINUTE || 5);
const CONTEXT_MESSAGE_LIMIT = Number(process.env.AGENT_CONTEXT_MESSAGE_LIMIT || 10);
const MESSAGE_BODY_TRUNCATE_CHARS = Number(process.env.AGENT_MESSAGE_TRUNCATE_CHARS || 500);
const MAX_REPLY_TOKENS = Number(process.env.AGENT_MAX_REPLY_TOKENS || 1024);
const AGENT_USER_ID = "agent";
const AGENT_DISPLAY_NAME = "Agent";

// Cached across warm Lambda invocations so we don't hit Secrets Manager on
// every single @agent mention.
let cachedApiKey;
async function getApiKey() {
  if (cachedApiKey) return cachedApiKey;
  const secret = await secretsClient.send(new GetSecretValueCommand({ SecretId: ANTHROPIC_SECRET_ARN }));
  cachedApiKey = secret.SecretString;
  return cachedApiKey;
}

let anthropicClient;
async function getClient() {
  if (anthropicClient) return anthropicClient;
  anthropicClient = new Anthropic({ apiKey: await getApiKey() });
  return anthropicClient;
}

// ---------------------------------------------------------------
// Fixed-window rate limit, one item per (userId, calendar minute). The
// window bucket is baked into the key so DynamoDB TTL cleans old windows
// up on its own — same TTL-based cleanup pattern used on the connections
// table. The increment + limit check happens as a single atomic
// conditional update, so concurrent invocations from the same user can't
// race past the limit.
// ---------------------------------------------------------------
async function checkRateLimit(userId) {
  const nowSeconds = Math.floor(Date.now() / 1000);
  const windowBucket = Math.floor(nowSeconds / 60);
  const rateLimitKey = `${userId}#${windowBucket}`;

  try {
    await db.send(new UpdateCommand({
      TableName: RATE_LIMIT_TABLE,
      Key: { rateLimitKey },
      UpdateExpression: "SET requestCount = if_not_exists(requestCount, :zero) + :one, expiresAt = if_not_exists(expiresAt, :ttl)",
      ConditionExpression: "attribute_not_exists(requestCount) OR requestCount < :limit",
      ExpressionAttributeValues: {
        ":zero": 0,
        ":one": 1,
        ":ttl": nowSeconds + 120, // window is 60s; a little slack before TTL sweep
        ":limit": RATE_LIMIT_PER_MINUTE,
      },
    }));
    return true;
  } catch (err) {
    if (err.name === "ConditionalCheckFailedException") return false;
    throw err;
  }
}

async function getRecentContext(roomId, excludeMessageId) {
  const result = await db.send(new QueryCommand({
    TableName: MESSAGES_TABLE,
    KeyConditionExpression: "roomId = :roomId",
    ExpressionAttributeValues: { ":roomId": roomId },
    ScanIndexForward: false, // newest first
    Limit: CONTEXT_MESSAGE_LIMIT + 1, // +1 in case the triggering message is in this page
  }));

  const items = (result.Items || [])
    .filter((item) => item.messageId !== excludeMessageId)
    .slice(0, CONTEXT_MESSAGE_LIMIT)
    .reverse(); // back to chronological order for the transcript

  return items.map((item) => `${item.displayName}: ${truncate(item.body, MESSAGE_BODY_TRUNCATE_CHARS)}`).join("\n");
}

async function postReply(roomId, text, replyToMessageId) {
  const createdAt = new Date().toISOString();
  const messageId = randomUUID();

  // Writing straight into the messages table — same as sendMessage — means
  // this reply rides the existing DynamoDB Stream → fanout → deliver
  // pipeline for free. It also can't re-trigger this Lambda: only
  // sendMessage's handler scans for @agent mentions, and this write never
  // goes through it, so there's no risk of the agent mentioning itself
  // into an invocation loop.
  await db.send(new PutCommand({
    TableName: MESSAGES_TABLE,
    Item: {
      roomId,
      sortKey: `${createdAt}#${messageId}`,
      messageId,
      userId: AGENT_USER_ID,
      displayName: AGENT_DISPLAY_NAME,
      body: text,
      createdAt,
      isAgent: true,
      replyToMessageId,
    },
  }));
}

exports.handler = async (event) => {
  const { roomId, userId, displayName, body, triggeringMessageId } = event;
  const log = (fields) => console.log(JSON.stringify({ event: "agent_invocation", roomId, userId, triggeringMessageId, ...fields }));

  if (!roomId || !userId || !body) {
    log({ outcome: "dropped_invalid_event" });
    return;
  }

  const allowed = await checkRateLimit(userId);
  if (!allowed) {
    // Deliberately silent — posting a "you're rate limited" chat message
    // would itself be an easy amplification vector for someone spamming
    // @agent. The invocation is dropped and logged instead.
    log({ outcome: "rate_limited" });
    return;
  }

  const startedAt = Date.now();
  try {
    const [context, client] = await Promise.all([
      getRecentContext(roomId, triggeringMessageId),
      getClient(),
    ]);

    const userTurn = buildUserTurn({ context, displayName, body, truncateChars: MESSAGE_BODY_TRUNCATE_CHARS });
    const response = await callClaude({ client, model: MODEL, maxTokens: MAX_REPLY_TOKENS, userTurn });

    log({
      outcome: "responded",
      model: response.model,
      stopReason: response.stop_reason,
      inputTokens: response.usage?.input_tokens,
      outputTokens: response.usage?.output_tokens,
      cacheReadTokens: response.usage?.cache_read_input_tokens,
      cacheCreationTokens: response.usage?.cache_creation_input_tokens,
      latencyMs: Date.now() - startedAt,
    });

    // Claude's own safety classifiers can decline the request outright —
    // that's a normal terminal state, not an error, so it gets a plain
    // reply rather than a crash or a retry loop.
    if (response.stop_reason === "refusal") {
      await postReply(roomId, "I can't help with that one.", triggeringMessageId);
      return;
    }

    const text = response.content
      .filter((block) => block.type === "text")
      .map((block) => block.text)
      .join("\n")
      .trim();

    if (!text) {
      log({ outcome: "empty_response" });
      return;
    }

    // Belt-and-suspenders cap on top of max_tokens — a chat bubble isn't a
    // document, and this also bounds the fan-out payload every connection
    // in the room receives.
    await postReply(roomId, truncate(text, MAX_REPLY_TOKENS * 4), triggeringMessageId);
  } catch (err) {
    log({ outcome: "error", error: err.message, latencyMs: Date.now() - startedAt });
    try {
      await postReply(roomId, "Sorry, I ran into a problem responding to that.", triggeringMessageId);
    } catch (postErr) {
      log({ outcome: "error_reply_failed", error: postErr.message });
    }
  }
};
