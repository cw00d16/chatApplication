const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, UpdateCommand, QueryCommand } = require("@aws-sdk/lib-dynamodb");
const { ApiGatewayManagementApiClient, PostToConnectionCommand } = require("@aws-sdk/client-apigatewaymanagementapi");

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

  const { roomId } = body;
  if (!roomId) return { statusCode: 400, body: "roomId is required" };

  await db.send(new UpdateCommand({
    TableName: CONNECTIONS_TABLE,
    Key: { connectionId },
    UpdateExpression: "SET roomId = :roomId",
    ExpressionAttributeValues: { ":roomId": roomId },
  }));

  // Send the joining connection the last 50 messages so it can render
  // history immediately, without waiting on a separate HTTP round trip.
  const history = await db.send(new QueryCommand({
    TableName: MESSAGES_TABLE,
    KeyConditionExpression: "roomId = :roomId",
    ExpressionAttributeValues: { ":roomId": roomId },
    ScanIndexForward: false,
    Limit: 50,
  }));

  await apiGw.send(new PostToConnectionCommand({
    ConnectionId: connectionId,
    Data: JSON.stringify({
      type: "history",
      roomId,
      messages: (history.Items || []).reverse(),
    }),
  }));

  return { statusCode: 200, body: "Joined" };
};
