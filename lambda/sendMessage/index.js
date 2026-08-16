const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, GetCommand, PutCommand } = require("@aws-sdk/lib-dynamodb");
const { LambdaClient, InvokeCommand } = require("@aws-sdk/client-lambda");
const { randomUUID } = require("crypto");

const client = new DynamoDBClient({});
const db = DynamoDBDocumentClient.from(client);
const lambdaClient = new LambdaClient({});
const CONNECTIONS_TABLE = process.env.CONNECTIONS_TABLE;
const MESSAGES_TABLE = process.env.MESSAGES_TABLE;
const AGENT_FUNCTION_NAME = process.env.AGENT_FUNCTION_NAME;

// Matches "@agent" as a standalone mention (word boundary on both sides,
// case-insensitive) — "@agent" triggers, "@agentsmith" doesn't.
const AGENT_MENTION_PATTERN = /(?:^|\s)@agent\b/i;

exports.handler = async (event) => {
  const connectionId = event.requestContext.connectionId;
  let body;
  try { body = JSON.parse(event.body || "{}"); }
  catch { return { statusCode: 400, body: "Invalid JSON" }; }

  const text = (body.body || "").trim();
  if (!text) return { statusCode: 400, body: "body is required" };

  // Sender's identity comes from the connection record set at $connect —
  // never trust a userId/displayName sent in the message payload itself.
  const conn = await db.send(new GetCommand({
    TableName: CONNECTIONS_TABLE,
    Key: { connectionId },
  }));
  if (!conn.Item?.roomId) return { statusCode: 400, body: "Not in a room" };

  const { userId, displayName, roomId } = conn.Item;
  const createdAt = new Date().toISOString();
  const messageId = randomUUID();

  const message = {
    roomId,
    sortKey: `${createdAt}#${messageId}`,
    messageId,
    userId,
    displayName,
    body: text,
    createdAt,
  };

  // Delivery to the room happens asynchronously, off of a DynamoDB Stream
  // on this table (see lambda/fanout) — not from here. That keeps this
  // handler's cost constant regardless of how many people are in the room,
  // and Streams retry a failed delivery batch automatically instead of a
  // crash here silently dropping the message for whoever hadn't gotten it yet.
  await db.send(new PutCommand({ TableName: MESSAGES_TABLE, Item: message }));

  // @agent mentions are handed off to a dedicated Lambda, fire-and-forget,
  // the same way fanout hands chunks off to deliver — this keeps
  // sendMessage's own latency and failure modes unaffected by anything
  // Claude-related. The agent Lambda posts its reply back into
  // MESSAGES_TABLE itself, so it rides the normal delivery pipeline too.
  if (AGENT_FUNCTION_NAME && AGENT_MENTION_PATTERN.test(text)) {
    await lambdaClient.send(new InvokeCommand({
      FunctionName: AGENT_FUNCTION_NAME,
      InvocationType: "Event",
      Payload: JSON.stringify({ roomId, userId, displayName, body: text, triggeringMessageId: messageId }),
    }));
  }

  return { statusCode: 200, body: "Sent" };
};
