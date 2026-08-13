const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, QueryCommand } = require("@aws-sdk/lib-dynamodb");
const { unmarshall } = require("@aws-sdk/util-dynamodb");
const { LambdaClient, InvokeCommand } = require("@aws-sdk/client-lambda");

const client = new DynamoDBClient({});
const db = DynamoDBDocumentClient.from(client);
const lambdaClient = new LambdaClient({});

const CONNECTIONS_TABLE = process.env.CONNECTIONS_TABLE;
const DELIVER_FUNCTION_NAME = process.env.DELIVER_FUNCTION_NAME;

const CHUNK_SIZE = 50; // connections handed to each deliver invocation

function chunk(items, size) {
  const chunks = [];
  for (let i = 0; i < items.length; i += size) chunks.push(items.slice(i, i + size));
  return chunks;
}

// ---------------------------------------------------------------
// Triggered by the messages table's DynamoDB Stream — sendMessage only
// persists the message; this is what actually delivers it. Splitting a
// room's connections into chunks and invoking `deliver` once per chunk
// (instead of looping through everyone here) is what lets a big room's
// fan-out run as many parallel Lambda invocations instead of one.
// ---------------------------------------------------------------
exports.handler = async (event) => {
  for (const record of event.Records) {
    if (record.eventName !== "INSERT") continue;

    const message = unmarshall(record.dynamodb.NewImage);

    const roomConnections = await db.send(new QueryCommand({
      TableName: CONNECTIONS_TABLE,
      IndexName: "roomId-index",
      KeyConditionExpression: "roomId = :roomId",
      ExpressionAttributeValues: { ":roomId": message.roomId },
      ProjectionExpression: "connectionId",
    }));

    const connectionIds = (roomConnections.Items || []).map((c) => c.connectionId);
    if (connectionIds.length === 0) continue;

    await Promise.all(chunk(connectionIds, CHUNK_SIZE).map((connectionIdChunk) =>
      lambdaClient.send(new InvokeCommand({
        FunctionName: DELIVER_FUNCTION_NAME,
        InvocationType: "Event", // fire-and-forget — deliver runs independently
        Payload: JSON.stringify({ connectionIds: connectionIdChunk, message }),
      }))
    ));
  }
};
