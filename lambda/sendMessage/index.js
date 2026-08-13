const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, GetCommand, PutCommand } = require("@aws-sdk/lib-dynamodb");
const { randomUUID } = require("crypto");

const client = new DynamoDBClient({});
const db = DynamoDBDocumentClient.from(client);
const CONNECTIONS_TABLE = process.env.CONNECTIONS_TABLE;
const MESSAGES_TABLE = process.env.MESSAGES_TABLE;

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

  return { statusCode: 200, body: "Sent" };
};
