const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, DeleteCommand } = require("@aws-sdk/lib-dynamodb");

const client = new DynamoDBClient({});
const db = DynamoDBDocumentClient.from(client);
const CONNECTIONS_TABLE = process.env.CONNECTIONS_TABLE;

exports.handler = async (event) => {
  await db.send(new DeleteCommand({
    TableName: CONNECTIONS_TABLE,
    Key: { connectionId: event.requestContext.connectionId },
  }));

  return { statusCode: 200, body: "Disconnected" };
};
