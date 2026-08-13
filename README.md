# chatApplication

Real-time multi-room chat, built serverless end-to-end on AWS with Terraform. Companion project to [urlShortener](https://github.com/cw00d16/urlShortener) — same infrastructure conventions, extended to a WebSocket-based real-time system.

## Architecture

```
React (S3 + CloudFront) ── Cognito (auth)
        │
        ├── HTTP API  ── Lambda (rooms, history) ── DynamoDB
        │
        └── WebSocket API ── Lambda (connect, disconnect, joinRoom, sendMessage) ── DynamoDB
```

- **Frontend**: React SPA on S3, served through CloudFront (OAC, no public bucket).
- **Auth**: Cognito User Pool. Access token is sent as a Bearer header on the HTTP API, and as a `?token=` query param on the WebSocket handshake (browsers can't set custom headers on a WS upgrade request).
- **Real-time transport**: API Gateway WebSocket API. One connection per session — switching rooms sends a `joinRoom` action over the existing socket rather than reconnecting, since `$connect` is the expensive step (JWT verification).
- **HTTP API**: room creation/listing and paginated message history — anything that isn't inherently real-time.
- **Data**: three DynamoDB tables — `connections`, `rooms`, `messages` — see `infrastructure/dynamodb.tf` for access patterns and item schemas.
- **CI/CD**: GitHub Actions assumes an AWS role via OIDC (no long-lived keys), deploys Lambda code and syncs the frontend build to S3 + CloudFront invalidation.

## Why WebSocket API + Lambda, not AppSync

AppSync (managed GraphQL subscriptions) would mean less code, but it hides the interesting part of this design: connection lifecycle, JWT verification without a header, and fan-out. Wiring it by hand is the point of the exercise.

## Known limitation: fan-out at scale

`sendMessage` queries every connection in a room and calls `postToConnection` on each one, from a single Lambda invocation. That's fine for small rooms but doesn't scale past a few hundred concurrent connections in one room — the Lambda's execution time and the WebSocket Management API's rate limits become the bottleneck.

The standard fix: decouple persistence from fan-out. Write the message, then publish to SNS/EventBridge (or use a DynamoDB Stream on the messages table) and let a separate fan-out Lambda — or several, sharded by connection — handle delivery in parallel. Not built here, since a single Lambda's fan-out is enough to demonstrate the mechanism, but worth calling out explicitly as the next scaling step.

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
