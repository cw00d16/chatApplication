# chatApplication

Real-time multi-room chat, built serverless end-to-end on AWS with Terraform. Companion project to [urlShortener](https://github.com/cw00d16/urlShortener) — same infrastructure conventions, extended to a WebSocket-based real-time system.

## Architecture

```
React (S3 + CloudFront) ── Cognito (auth)
        │
        ├── HTTP API  ── Lambda (rooms, history) ── DynamoDB
        │
        └── WebSocket API ── Lambda (connect, disconnect, joinRoom, sendMessage) ── DynamoDB
                                                                        │
                                                              DynamoDB Stream
                                                                        │
                                                                     fanout ── deliver (× N, parallel)
```

- **Frontend**: React SPA on S3, served through CloudFront (OAC, no public bucket).
- **Auth**: Cognito User Pool. Access token is sent as a Bearer header on the HTTP API, and as a `?token=` query param on the WebSocket handshake (browsers can't set custom headers on a WS upgrade request).
- **Real-time transport**: API Gateway WebSocket API. One connection per session — switching rooms sends a `joinRoom` action over the existing socket rather than reconnecting, since `$connect` is the expensive step (JWT verification).
- **HTTP API**: room creation/listing and paginated message history — anything that isn't inherently real-time.
- **Data**: three DynamoDB tables — `connections`, `rooms`, `messages` — see `infrastructure/dynamodb.tf` for access patterns and item schemas.
- **CI/CD**: GitHub Actions assumes an AWS role via OIDC (no long-lived keys), deploys Lambda code and syncs the frontend build to S3 + CloudFront invalidation.

## Why WebSocket API + Lambda, not AppSync

AppSync (managed GraphQL subscriptions) would mean less code, but it hides the interesting part of this design: connection lifecycle, JWT verification without a header, and fan-out. Wiring it by hand is the point of the exercise.

## Fan-out: decoupled via DynamoDB Streams

`sendMessage` only persists the message — it doesn't touch delivery at all. A DynamoDB Stream on the `messages` table triggers `fanout`, which looks up who's in the room, splits the connections into chunks of 50, and asynchronously invokes `deliver` once per chunk. A large room's delivery therefore runs as many parallel Lambda invocations instead of one Lambda looping through every connection — and because Streams retry a failed batch automatically, a crash mid-delivery no longer silently drops the message the way it would with delivery inline in `sendMessage`.

The cost of that: a small amount of added latency between "message saved" and "message delivered" (stream processing time, typically well under a second), since delivery is no longer synchronous with the send. Worth calling out as the explicit tradeoff — durability and horizontal scalability, at the cost of a little end-to-end latency.

## Deploying

```
cd infrastructure
cp terraform.tfvars.example terraform.tfvars   # fill in your GitHub repo, region, etc.
terraform init
terraform apply
```

Then copy the values from `terraform output frontend_env_vars` into `frontend/.env` (see `frontend/.env.example`) for local development, or into GitHub Actions repo secrets for CI deploys:

- `AWS_ROLE_ARN` (from `terraform output github_actions_role_arn`)
- `S3_BUCKET_NAME` (from `terraform output s3_bucket_name`)
- `CLOUDFRONT_DISTRIBUTION_ID`
- `REACT_APP_API_URL`, `REACT_APP_WEBSOCKET_URL`, `REACT_APP_COGNITO_USER_POOL`, `REACT_APP_COGNITO_CLIENT_ID`

## Local development

```
cd frontend
cp .env.example .env   # fill in terraform outputs
npm install
npm start
```
