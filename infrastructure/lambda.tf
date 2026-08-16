# ---------------------------------------------------------------
# Lambda functions
# Terraform zips the source from the lambda/ directory at plan time
# ---------------------------------------------------------------

# --- IAM role shared by all Lambda functions ---
resource "aws_iam_role" "lambda" {
  name = "${local.prefix}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# X-Ray write access (telemetry only — no read access to any resource) so
# sendMessage can emit trace segments. Only sendMessage actually has active
# tracing turned on below; attaching this to the shared role doesn't change
# what any other function on it can do.
resource "aws_iam_role_policy_attachment" "lambda_xray" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# DynamoDB access for all Lambda functions
resource "aws_iam_role_policy" "lambda_dynamo" {
  name = "${local.prefix}-lambda-dynamo"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Query",
        "dynamodb:Scan"
      ]
      Resource = [
        aws_dynamodb_table.connections.arn,
        "${aws_dynamodb_table.connections.arn}/index/*",
        aws_dynamodb_table.rooms.arn,
        "${aws_dynamodb_table.rooms.arn}/index/*",
        aws_dynamodb_table.messages.arn,
        "${aws_dynamodb_table.messages.arn}/index/*"
      ]
    }]
  })
}

# Push messages back down open WebSocket connections
resource "aws_iam_role_policy" "lambda_manage_connections" {
  name = "${local.prefix}-lambda-manage-connections"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["execute-api:ManageConnections"]
      Resource = "${aws_apigatewayv2_api.chat.execution_arn}/*"
    }]
  })
}

# fanout reads the messages table's DynamoDB Stream
resource "aws_iam_role_policy" "lambda_stream_read" {
  name = "${local.prefix}-lambda-stream-read"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:DescribeStream",
        "dynamodb:GetRecords",
        "dynamodb:GetShardIterator",
        "dynamodb:ListStreams"
      ]
      Resource = aws_dynamodb_table.messages.stream_arn
    }]
  })
}

# fanout invokes deliver directly (not through API Gateway or a stream)
resource "aws_iam_role_policy" "lambda_invoke_deliver" {
  name = "${local.prefix}-lambda-invoke-deliver"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = aws_lambda_function.deliver.arn
    }]
  })
}

# sendMessage invokes agent directly (fire-and-forget) when a message
# contains an @agent mention
resource "aws_iam_role_policy" "lambda_invoke_agent" {
  name = "${local.prefix}-lambda-invoke-agent"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = aws_lambda_function.agent.arn
    }]
  })
}

# --- Common environment variables for all functions ---
locals {
  lambda_environment = {
    CONNECTIONS_TABLE   = aws_dynamodb_table.connections.name
    ROOMS_TABLE         = aws_dynamodb_table.rooms.name
    MESSAGES_TABLE      = aws_dynamodb_table.messages.name
    USER_POOL_ID        = aws_cognito_user_pool.main.id
    USER_POOL_CLIENT_ID = aws_cognito_user_pool_client.frontend.id
    AWS_REGION_         = var.aws_region
  }

  # $connect/joinRoom/deliver additionally need the management API endpoint
  # to push messages back down open connections via postToConnection
  ws_environment = merge(local.lambda_environment, {
    WEBSOCKET_ENDPOINT = "https://${aws_apigatewayv2_api.chat.id}.execute-api.${var.aws_region}.amazonaws.com/${aws_apigatewayv2_stage.chat.name}"
  })

  # fanout additionally needs to know which function to invoke per chunk
  fanout_environment = merge(local.lambda_environment, {
    DELIVER_FUNCTION_NAME = aws_lambda_function.deliver.function_name
  })

  # sendMessage additionally needs to know which function to hand @agent
  # mentions off to
  send_message_environment = merge(local.lambda_environment, {
    AGENT_FUNCTION_NAME = aws_lambda_function.agent.function_name
  })

  # agent's own environment — deliberately not built on local.lambda_environment:
  # it doesn't touch the connections/rooms tables or Cognito, so it gets only
  # what it actually uses (see the dedicated IAM role below).
  agent_environment = {
    MESSAGES_TABLE         = aws_dynamodb_table.messages.name
    AGENT_RATE_LIMIT_TABLE = aws_dynamodb_table.agent_rate_limits.name
    ANTHROPIC_SECRET_ARN   = aws_secretsmanager_secret.anthropic_api_key.arn
  }
}

# --- CloudWatch log groups — one per function ---
resource "aws_cloudwatch_log_group" "connect" {
  name              = "/aws/lambda/${local.prefix}-connect"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "disconnect" {
  name              = "/aws/lambda/${local.prefix}-disconnect"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "join_room" {
  name              = "/aws/lambda/${local.prefix}-join-room"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "send_message" {
  name              = "/aws/lambda/${local.prefix}-send-message"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "fanout" {
  name              = "/aws/lambda/${local.prefix}-fanout"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "deliver" {
  name              = "/aws/lambda/${local.prefix}-deliver"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "rooms" {
  name              = "/aws/lambda/${local.prefix}-rooms"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "history" {
  name              = "/aws/lambda/${local.prefix}-history"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "agent" {
  name              = "/aws/lambda/${local.prefix}-agent"
  retention_in_days = 14
}

# --- Zip the Lambda source code ---
data "archive_file" "connect" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/connect"
  output_path = "${path.module}/.lambda_builds/connect.zip"
}

data "archive_file" "disconnect" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/disconnect"
  output_path = "${path.module}/.lambda_builds/disconnect.zip"
}

data "archive_file" "join_room" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/joinRoom"
  output_path = "${path.module}/.lambda_builds/joinRoom.zip"
}

data "archive_file" "send_message" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/sendMessage"
  output_path = "${path.module}/.lambda_builds/sendMessage.zip"
}

data "archive_file" "fanout" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/fanout"
  output_path = "${path.module}/.lambda_builds/fanout.zip"
}

data "archive_file" "deliver" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/deliver"
  output_path = "${path.module}/.lambda_builds/deliver.zip"
}

data "archive_file" "rooms" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/rooms"
  output_path = "${path.module}/.lambda_builds/rooms.zip"
}

data "archive_file" "history" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/history"
  output_path = "${path.module}/.lambda_builds/history.zip"
}

# agent is the only Lambda with a real npm dependency (@anthropic-ai/sdk —
# every other function only uses the AWS SDK v3, which ships in the Node.js
# 20 Lambda runtime and needs no bundling). archive_file just zips whatever
# is on disk, so node_modules has to exist before it runs; this installs it
# whenever package.json/package-lock.json change, rather than relying on
# whoever runs `terraform apply` to remember a manual `npm install` step.
resource "null_resource" "agent_npm_install" {
  triggers = {
    package_lock_hash = filesha256("${path.module}/../lambda/agent/package-lock.json")
  }

  provisioner "local-exec" {
    command     = "npm ci --omit=dev"
    working_dir = "${path.module}/../lambda/agent"
  }
}

data "archive_file" "agent" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/agent"
  output_path = "${path.module}/.lambda_builds/agent.zip"
  depends_on  = [null_resource.agent_npm_install]
}

# --- connect Lambda ---
resource "aws_lambda_function" "connect" {
  function_name    = "${local.prefix}-connect"
  role             = aws_iam_role.lambda.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.connect.output_path
  source_code_hash = data.archive_file.connect.output_base64sha256
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_seconds

  environment {
    variables = local.lambda_environment
  }

  depends_on = [aws_cloudwatch_log_group.connect]
}

# --- disconnect Lambda ---
resource "aws_lambda_function" "disconnect" {
  function_name    = "${local.prefix}-disconnect"
  role             = aws_iam_role.lambda.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.disconnect.output_path
  source_code_hash = data.archive_file.disconnect.output_base64sha256
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_seconds

  environment {
    variables = local.lambda_environment
  }

  depends_on = [aws_cloudwatch_log_group.disconnect]
}

# --- joinRoom Lambda ---
resource "aws_lambda_function" "join_room" {
  function_name    = "${local.prefix}-join-room"
  role             = aws_iam_role.lambda.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.join_room.output_path
  source_code_hash = data.archive_file.join_room.output_base64sha256
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_seconds

  environment {
    variables = local.ws_environment
  }

  depends_on = [aws_cloudwatch_log_group.join_room]
}

# --- sendMessage Lambda ---
# Only persists the message — delivery happens asynchronously via fanout,
# triggered by the messages table's DynamoDB Stream (see below).
resource "aws_lambda_function" "send_message" {
  function_name    = "${local.prefix}-send-message"
  role             = aws_iam_role.lambda.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.send_message.output_path
  source_code_hash = data.archive_file.send_message.output_base64sha256
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_seconds

  environment {
    variables = local.send_message_environment
  }

  # Active tracing only on sendMessage and agent — the two hops in an
  # @agent turn where "why was this slow" actually needs a trace (DynamoDB
  # time vs. Claude API time vs. tool-call round trips). Every other
  # function here is a fixed-cost DynamoDB read/write with nothing to trace.
  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.send_message]
}

# --- deliver Lambda ---
# Invoked directly by fanout (never by API Gateway or a stream) with one
# chunk of a room's connections to push a message down.
resource "aws_lambda_function" "deliver" {
  function_name    = "${local.prefix}-deliver"
  role             = aws_iam_role.lambda.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.deliver.output_path
  source_code_hash = data.archive_file.deliver.output_base64sha256
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_seconds

  environment {
    variables = local.ws_environment
  }

  depends_on = [aws_cloudwatch_log_group.deliver]
}

# --- fanout Lambda ---
# Triggered by the messages table's DynamoDB Stream. Looks up who's in the
# room and hands chunks of connections off to parallel `deliver` invocations.
resource "aws_lambda_function" "fanout" {
  function_name    = "${local.prefix}-fanout"
  role             = aws_iam_role.lambda.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.fanout.output_path
  source_code_hash = data.archive_file.fanout.output_base64sha256
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_seconds

  environment {
    variables = local.fanout_environment
  }

  depends_on = [aws_cloudwatch_log_group.fanout]
}

# Wires the messages table's stream to fanout. batch_size=1 keeps delivery
# latency low; DynamoDB Streams retries a failed batch automatically up to
# maximum_retry_attempts before giving up on it.
resource "aws_lambda_event_source_mapping" "messages_stream" {
  event_source_arn       = aws_dynamodb_table.messages.stream_arn
  function_name          = aws_lambda_function.fanout.arn
  starting_position      = "LATEST"
  batch_size             = 1
  maximum_retry_attempts = 3
}

# --- rooms Lambda (list + create) ---
resource "aws_lambda_function" "rooms" {
  function_name    = "${local.prefix}-rooms"
  role             = aws_iam_role.lambda.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.rooms.output_path
  source_code_hash = data.archive_file.rooms.output_base64sha256
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_seconds

  environment {
    variables = local.lambda_environment
  }

  depends_on = [aws_cloudwatch_log_group.rooms]
}

resource "aws_lambda_permission" "rooms" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rooms.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# --- history Lambda ---
resource "aws_lambda_function" "history" {
  function_name    = "${local.prefix}-history"
  role             = aws_iam_role.lambda.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.history.output_path
  source_code_hash = data.archive_file.history.output_base64sha256
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_seconds

  environment {
    variables = local.lambda_environment
  }

  depends_on = [aws_cloudwatch_log_group.history]
}

resource "aws_lambda_permission" "history" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.history.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# ---------------------------------------------------------------
# agent Lambda — its own IAM role rather than the shared one every other
# function uses. It never reads/writes connections or rooms and never
# calls the WebSocket management API directly (it replies by writing to
# messages, same as sendMessage, and rides the existing fanout/deliver
# pipeline from there), so it gets a narrower policy: PutItem + Query on
# messages, UpdateItem on its own rate-limit table, and GetSecretValue on
# exactly one secret. Compromise of this function's credentials can't
# read message history it wasn't already given, delete anything, or touch
# any other table.
# ---------------------------------------------------------------

resource "aws_iam_role" "agent_lambda" {
  name = "${local.prefix}-agent-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "agent_lambda_basic" {
  role       = aws_iam_role.agent_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "agent_lambda_xray" {
  role       = aws_iam_role.agent_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy" "agent_dynamo" {
  name = "${local.prefix}-agent-dynamo"
  role = aws_iam_role.agent_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:Query"]
        Resource = aws_dynamodb_table.messages.arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.agent_rate_limits.arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "agent_secrets" {
  name = "${local.prefix}-agent-secrets"
  role = aws_iam_role.agent_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.anthropic_api_key.arn
    }]
  })
}

resource "aws_lambda_function" "agent" {
  function_name    = "${local.prefix}-agent"
  role             = aws_iam_role.agent_lambda.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.agent.output_path
  source_code_hash = data.archive_file.agent.output_base64sha256
  memory_size      = var.lambda_memory_mb
  # Overrides the shared 10s default — a Claude call (plus an optional web
  # search round trip) routinely takes longer than the quick DynamoDB CRUD
  # every other function here does.
  timeout = 30

  environment {
    variables = local.agent_environment
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.agent]
}
