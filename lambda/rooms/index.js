const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, PutCommand, QueryCommand } = require("@aws-sdk/lib-dynamodb");
const { randomUUID } = require("crypto");

const client = new DynamoDBClient({});
const db = DynamoDBDocumentClient.from(client);
const TABLE = process.env.ROOMS_TABLE;

function response(statusCode, body) {
  return {
    statusCode,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  };
}

function slugify(name) {
  return name.toLowerCase().trim().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "");
}

exports.handler = async (event) => {
  const userId = event.requestContext?.authorizer?.jwt?.claims?.sub;
  if (!userId) return response(401, { error: "Unauthorized" });

  const method = event.requestContext.http.method;

  // GET /api/rooms — list all rooms, newest first
  if (method === "GET") {
    const result = await db.send(new QueryCommand({
      TableName: TABLE,
      IndexName: "listKey-createdAt-index",
      KeyConditionExpression: "listKey = :lk",
      ExpressionAttributeValues: { ":lk": "ROOM" },
      ScanIndexForward: false,
      Limit: 100,
    }));

    return response(200, result.Items || []);
  }

  // POST /api/rooms — create a room
  if (method === "POST") {
    let body;
    try { body = JSON.parse(event.body || "{}"); }
    catch { return response(400, { error: "Invalid JSON" }); }

    const name = (body.name || "").trim();
    if (!name) return response(400, { error: "name is required" });

    const roomId = `${slugify(name)}-${randomUUID().slice(0, 8)}`;
    const createdAt = new Date().toISOString();

    await db.send(new PutCommand({
      TableName: TABLE,
      Item: { roomId, listKey: "ROOM", name, createdBy: userId, createdAt },
      ConditionExpression: "attribute_not_exists(roomId)",
    }));

    return response(200, { roomId, name, createdAt });
  }

  return response(405, { error: "Method not allowed" });
};
