const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, GetCommand, PutCommand, QueryCommand } = require("@aws-sdk/lib-dynamodb");
const { ApiGatewayManagementApiClient, PostToConnectionCommand } = require("@aws-sdk/client-apigatewaymanagementapi");
const { randomUUID } = require("crypto");

const client = new DynamoDBClient({});
const db = DynamoDBDocumentClient.from(client);
const CONNECTIONS_TABLE = process.env.CONNECTIONS_TABLE;
const MESSAGES_TABLE = process.env.MESSAGES_TABLE;

const apiGw = new ApiGatewayManagementApiClient({ endpoint: process.env.WEBSOCKET_ENDPOINT });

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

  await db.send(new PutCommand({ TableName: MESSAGES_TABLE, Item: message }));

  // Fan out to every connection currently in this room
  const roomConnections = await db.send(new QueryCommand({
    TableName: CONNECTIONS_TABLE,
    IndexName: "roomId-index",
    KeyConditionExpression: "roomId = :roomId",
    ExpressionAttributeValues: { ":roomId": roomId },
  }));

  const payload = JSON.stringify({ type: "message", message });

  await Promise.all((roomConnections.Items || []).map(async ({ connectionId: targetId }) => {
    try {
      await apiGw.send(new PostToConnectionCommand({ ConnectionId: targetId, Data: payload }));
    } catch (err) {
      // 410 Gone means the client disconnected without a clean $disconnect —
      // stale row will also be swept by the connections table's TTL.
      if (err.name !== "GoneException") console.error(`Failed to deliver to ${targetId}:`, err);
    }
  }));

  return { statusCode: 200, body: "Sent" };
};
