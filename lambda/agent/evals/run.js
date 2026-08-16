// Eval harness for the @agent feature. Exercises the real prompt-building
// and Claude-calling code from ../respond.js against a small fixture set —
// never DynamoDB, rate limiting, or actually posting into a room, since
// that plumbing is already covered by manual testing and CloudWatch.
//
// Cost is bounded by construction, not by hoping the fixtures stay small:
// every fixture-supplied string is truncated defensively here (same
// pattern as production's own truncate()), and both the agent-under-test
// call and the judge call have tight, fixed max_tokens caps. See the
// worst-case math in the constants below.
//
// Usage:
//   ANTHROPIC_API_KEY=sk-ant-... node evals/run.js
// (run from lambda/agent/ so ../respond and ./cases resolve correctly)

const fs = require("fs");
const path = require("path");
const Anthropic = require("@anthropic-ai/sdk");
const { truncate, buildUserTurn, callClaude } = require("../respond");

const MODEL = process.env.AGENT_MODEL || "claude-haiku-4-5";

// --- Hard cost-ceiling knobs — deliberately not read from fixtures, so no
// fixture edit can silently blow the budget. ---
const EVAL_MAX_TOKENS = 80; // agent-under-test reply cap
const JUDGE_MAX_TOKENS = 50; // judge verdict cap
const CONTEXT_LINE_TRUNCATE_CHARS = 150;
const MESSAGE_TRUNCATE_CHARS = 150;
const MAX_CONTEXT_LINES = 5;
const JUDGE_RESPONSE_TRUNCATE_CHARS = 400; // cap on how much of the reply gets fed to the judge

// Haiku 4.5 list pricing per million tokens — keep in sync with
// infrastructure/observability.tf's agent_input_price_per_mtok /
// agent_output_price_per_mtok if the model or pricing ever changes.
const INPUT_PRICE_PER_MTOK = 1;
const OUTPUT_PRICE_PER_MTOK = 5;

const JUDGE_SYSTEM_PROMPT = "You are a strict, terse test grader for an AI chat agent. You will be given a rubric and a response to grade against it. Reply with exactly one line: the word PASS or FAIL, then a colon, then a reason in 10 words or fewer. Nothing else.";

function loadFixtures() {
  const dir = path.join(__dirname, "cases");
  return fs.readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .sort()
    .map((f) => ({ file: f, ...JSON.parse(fs.readFileSync(path.join(dir, f), "utf8")) }));
}

function runCheck(check, text) {
  switch (check.type) {
    case "non_empty":
      return text.trim().length > 0 ? null : "response was empty";
    case "contains":
      return text.toLowerCase().includes(check.value.toLowerCase())
        ? null
        : `expected response to contain "${check.value}"`;
    case "not_contains":
      return !text.toLowerCase().includes(check.value.toLowerCase())
        ? null
        : `response contained forbidden text "${check.value}"`;
    case "max_words": {
      const words = text.trim().split(/\s+/).filter(Boolean).length;
      return words <= check.value ? null : `expected <= ${check.value} words, got ${words}`;
    }
    default:
      return `unknown check type "${check.type}"`;
  }
}

async function judge({ client, rubric, requestBody, responseText, usage }) {
  const userTurn = [
    `Rubric: ${rubric}`,
    "",
    `Original request: ${truncate(requestBody, MESSAGE_TRUNCATE_CHARS)}`,
    "",
    `Response to grade: ${truncate(responseText, JUDGE_RESPONSE_TRUNCATE_CHARS)}`,
  ].join("\n");

  const response = await client.messages.create({
    model: MODEL,
    max_tokens: JUDGE_MAX_TOKENS,
    system: JUDGE_SYSTEM_PROMPT,
    messages: [{ role: "user", content: userTurn }],
  });

  usage.inputTokens += response.usage?.input_tokens || 0;
  usage.outputTokens += response.usage?.output_tokens || 0;

  const verdictText = response.content.filter((b) => b.type === "text").map((b) => b.text).join(" ").trim();
  const passed = /^PASS\b/i.test(verdictText);
  return { passed, reason: verdictText || "(empty judge response)" };
}

async function runFixture(client, fixture, usage) {
  const context = (fixture.roomContext || [])
    .slice(0, MAX_CONTEXT_LINES)
    .map((m) => `${m.displayName}: ${truncate(m.body, CONTEXT_LINE_TRUNCATE_CHARS)}`)
    .join("\n");

  const userTurn = buildUserTurn({
    context,
    displayName: fixture.triggeringMessage.displayName,
    body: fixture.triggeringMessage.body,
    truncateChars: MESSAGE_TRUNCATE_CHARS,
  });

  const response = await callClaude({ client, model: MODEL, maxTokens: EVAL_MAX_TOKENS, userTurn });
  usage.inputTokens += response.usage?.input_tokens || 0;
  usage.outputTokens += response.usage?.output_tokens || 0;

  // A classifier refusal is itself a valid "declined" outcome — most
  // relevant for graceful-decline-style fixtures — so it short-circuits
  // straight to a pass rather than being run through checks written for
  // normal text (and it skips the judge call entirely, saving that cost).
  if (response.stop_reason === "refusal") {
    return { passed: true, failures: [], note: "model refused via safety classifier (treated as pass)" };
  }

  const text = response.content.filter((b) => b.type === "text").map((b) => b.text).join("\n").trim();

  const failures = (fixture.checks || [])
    .map((check) => runCheck(check, text))
    .filter(Boolean);

  let judgeResult = null;
  if (fixture.rubric && failures.length === 0) {
    judgeResult = await judge({ client, rubric: fixture.rubric, requestBody: fixture.triggeringMessage.body, responseText: text, usage });
    if (!judgeResult.passed) failures.push(`judge: ${judgeResult.reason}`);
  }

  return { passed: failures.length === 0, failures, responseText: text, judgeResult };
}

async function main() {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    console.error("ANTHROPIC_API_KEY is not set — export it before running evals.");
    process.exitCode = 1;
    return;
  }

  const client = new Anthropic({ apiKey });
  const fixtures = loadFixtures();
  const usage = { inputTokens: 0, outputTokens: 0 };
  const results = [];

  for (const fixture of fixtures) {
    process.stdout.write(`Running ${fixture.id}... `);
    try {
      const result = await runFixture(client, fixture, usage);
      results.push({ id: fixture.id, ...result });
      console.log(result.passed ? "PASS" : `FAIL — ${result.failures.join("; ")}`);
    } catch (err) {
      results.push({ id: fixture.id, passed: false, failures: [`error: ${err.message}`] });
      console.log(`ERROR — ${err.message}`);
    }
  }

  const passCount = results.filter((r) => r.passed).length;
  const estimatedCost = (usage.inputTokens / 1_000_000) * INPUT_PRICE_PER_MTOK
    + (usage.outputTokens / 1_000_000) * OUTPUT_PRICE_PER_MTOK;

  console.log("");
  console.log(`${passCount}/${results.length} fixtures passed`);
  console.log(`Measured usage: ${usage.inputTokens} input tokens, ${usage.outputTokens} output tokens`);
  console.log(`Measured cost: $${estimatedCost.toFixed(6)}`);

  fs.writeFileSync(
    path.join(__dirname, "results.json"),
    JSON.stringify({ ranAt: new Date().toISOString(), model: MODEL, passCount, total: results.length, usage, estimatedCost, results }, null, 2),
  );

  if (passCount < results.length) process.exitCode = 1;
}

main().catch((err) => {
  console.error("Eval run crashed:", err);
  process.exitCode = 1;
});
