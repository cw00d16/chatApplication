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

  # $connect/joinRoom/sendMessage additionally need the management API endpoint
  # to push messages back down open connections via postToConnection
  ws_environment = merge(local.lambda_environment, {
    WEBSOCKET_ENDPOINT = "https://${aws_apigatewayv2_api.chat.id}.execute-api.${var.aws_region}.amazonaws.com/${aws_apigatewayv2_stage.chat.name}"
  })
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

resource "aws_cloudwatch_log_group" "rooms" {
  name              = "/aws/lambda/${local.prefix}-rooms"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "history" {
  name              = "/aws/lambda/${local.prefix}-history"
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
    variables = local.ws_environment
  }

  depends_on = [aws_cloudwatch_log_group.send_message]
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
