const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, QueryCommand } = require("@aws-sdk/lib-dynamodb");

const client = new DynamoDBClient({});
const db = DynamoDBDocumentClient.from(client);
const TABLE = process.env.MESSAGES_TABLE;

function response(statusCode, body) {
  return {
    statusCode,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  };
}

exports.handler = async (event) => {
  const userId = event.requestContext?.authorizer?.jwt?.claims?.sub;
  if (!userId) return response(401, { error: "Unauthorized" });

  const roomId = event.pathParameters?.roomId;
  if (!roomId) return response(400, { error: "Missing roomId" });

  const limit = Math.min(Number(event.queryStringParameters?.limit) || 50, 100);
  const cursor = event.queryStringParameters?.cursor;

  let exclusiveStartKey;
  if (cursor) {
    try { exclusiveStartKey = JSON.parse(Buffer.from(cursor, "base64").toString("utf8")); }
    catch { return response(400, { error: "Invalid cursor" }); }
  }

  // Newest-first pages, older messages paged in via the cursor —
  // the client reverses each page before rendering to keep chat order.
  const result = await db.send(new QueryCommand({
    TableName: TABLE,
    KeyConditionExpression: "roomId = :roomId",
    ExpressionAttributeValues: { ":roomId": roomId },
    ScanIndexForward: false,
    Limit: limit,
    ExclusiveStartKey: exclusiveStartKey,
  }));

  const nextCursor = result.LastEvaluatedKey
    ? Buffer.from(JSON.stringify(result.LastEvaluatedKey)).toString("base64")
    : null;

  return response(200, { messages: result.Items || [], nextCursor });
};
