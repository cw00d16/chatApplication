const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, PutCommand } = require("@aws-sdk/lib-dynamodb");
const { createPublicKey, verify: cryptoVerify } = require("crypto");
const https = require("https");

const client = new DynamoDBClient({});
const db = DynamoDBDocumentClient.from(client);
const CONNECTIONS_TABLE = process.env.CONNECTIONS_TABLE;
const USER_POOL_ID = process.env.USER_POOL_ID;
const USER_POOL_CLIENT_ID = process.env.USER_POOL_CLIENT_ID;
const REGION = process.env.AWS_REGION_;
const ISSUER = `https://cognito-idp.${REGION}.amazonaws.com/${USER_POOL_ID}`;

// ---------------------------------------------------------------
// WebSocket $connect can't carry an Authorization header, so the
// browser sends the Cognito access token as a query string param.
// We verify it here by hand against Cognito's public JWKS — no
// external JWT library, just Node's built-in crypto (matches the
// rest of this project's zero-dependency Lambda approach).
//
// JWKS is fetched once per warm Lambda container and cached in
// module scope, since it rarely changes and Cognito rate-limits it.
// ---------------------------------------------------------------

let jwksCache = null;

function base64UrlDecode(input) {
  return Buffer.from(input.replace(/-/g, "+").replace(/_/g, "/"), "base64");
}

function fetchJwks() {
  if (jwksCache) return Promise.resolve(jwksCache);
  return new Promise((resolve, reject) => {
    https.get(`${ISSUER}/.well-known/jwks.json`, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => {
        try {
          jwksCache = JSON.parse(data).keys;
          resolve(jwksCache);
        } catch (err) {
          reject(err);
        }
      });
    }).on("error", reject);
  });
}

async function verifyToken(token) {
  const [headerB64, payloadB64, sigB64] = token.split(".");
  if (!headerB64 || !payloadB64 || !sigB64) throw new Error("Malformed token");

  const header = JSON.parse(base64UrlDecode(headerB64).toString("utf8"));
  const payload = JSON.parse(base64UrlDecode(payloadB64).toString("utf8"));

  const jwks = await fetchJwks();
  const jwk = jwks.find((k) => k.kid === header.kid);
  if (!jwk) throw new Error("No matching JWK");

  const publicKey = createPublicKey({ key: jwk, format: "jwk" });
  const signedData = `${headerB64}.${payloadB64}`;
  const signature = base64UrlDecode(sigB64);
  const valid = cryptoVerify("RSA-SHA256", Buffer.from(signedData), publicKey, signature);
  if (!valid) throw new Error("Invalid signature");

  if (payload.iss !== ISSUER) throw new Error("Invalid issuer");
  if (payload.token_use !== "access") throw new Error("Not an access token");
  if (payload.client_id !== USER_POOL_CLIENT_ID) throw new Error("Invalid client_id");
  if (payload.exp * 1000 < Date.now()) throw new Error("Token expired");

  return payload; // includes sub, username, exp, etc.
}

exports.handler = async (event) => {
  const token = event.queryStringParameters?.token;
  const displayName = event.queryStringParameters?.displayName || "Anonymous";

  if (!token) return { statusCode: 401, body: "Missing token" };

  let claims;
  try {
    claims = await verifyToken(token);
  } catch (err) {
    console.error("Token verification failed:", err.message);
    return { statusCode: 401, body: "Unauthorized" };
  }

  const now = Date.now();
  await db.send(new PutCommand({
    TableName: CONNECTIONS_TABLE,
    Item: {
      connectionId: event.requestContext.connectionId,
      userId: claims.sub,
      displayName,
      roomId: "",
      connectedAt: new Date(now).toISOString(),
      expiresAt: Math.floor(now / 1000) + 60 * 60 * 24, // 24h TTL safety net
    },
  }));

  return { statusCode: 200, body: "Connected" };
};
