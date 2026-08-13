const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, DeleteCommand } = require("@aws-sdk/lib-dynamodb");
const { ApiGatewayManagementApiClient, PostToConnectionCommand } = require("@aws-sdk/client-apigatewaymanagementapi");

const client = new DynamoDBClient({});
const db = DynamoDBDocumentClient.from(client);
const CONNECTIONS_TABLE = process.env.CONNECTIONS_TABLE;

const apiGw = new ApiGatewayManagementApiClient({ endpoint: process.env.WEBSOCKET_ENDPOINT });

// ---------------------------------------------------------------
// Invoked directly by fanout (not through API Gateway or a stream) with
// one chunk of a room's connections. Each invocation only ever handles
// its own chunk, so many of these run concurrently for a large room
// instead of a single Lambda delivering to everyone itself.
// ---------------------------------------------------------------
exports.handler = async (event) => {
  const { connectionIds, message } = event;
  const payload = JSON.stringify({ type: "message", message });

  await Promise.all(connectionIds.map(async (connectionId) => {
    try {
      await apiGw.send(new PostToConnectionCommand({ ConnectionId: connectionId, Data: payload }));
    } catch (err) {
      // 410 Gone means the client disconnected without a clean $disconnect —
      // clean the stale row up now instead of waiting on the TTL sweep.
      if (err.name === "GoneException") {
        await db.send(new DeleteCommand({ TableName: CONNECTIONS_TABLE, Key: { connectionId } }));
      } else {
        console.error(`Failed to deliver to ${connectionId}:`, err);
      }
    }
  }));
};
