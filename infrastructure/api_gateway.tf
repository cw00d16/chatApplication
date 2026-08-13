# ---------------------------------------------------------------
# API Gateway v2 (HTTP API) — routes to Lambda functions
# Used for everything that isn't real-time (rooms, history)
# ---------------------------------------------------------------

resource "aws_apigatewayv2_api" "main" {
  name          = "${local.prefix}-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins  = ["*"]
    allow_methods  = ["GET", "POST", "OPTIONS"]
    allow_headers  = ["Content-Type", "Authorization"]
    expose_headers = []
    max_age        = 86400
  }
}

resource "aws_apigatewayv2_stage" "main" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = var.environment
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format          = "$context.requestId $context.status"
  }

  default_route_settings {
    throttling_burst_limit = 100
    throttling_rate_limit  = 50
  }
}

# Cognito JWT authorizer — validates tokens on protected routes
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.main.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "${local.prefix}-cognito-authorizer"

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.frontend.id]
    issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
  }
}

# --- Routes ---

# GET /api/rooms — list all rooms (auth required)
# POST /api/rooms — create a room (auth required)
resource "aws_apigatewayv2_integration" "rooms" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.rooms.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "list_rooms" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "GET /api/rooms"
  target             = "integrations/${aws_apigatewayv2_integration.rooms.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "create_room" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "POST /api/rooms"
  target             = "integrations/${aws_apigatewayv2_integration.rooms.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

# GET /api/rooms/{roomId}/messages — paginated chat history (auth required)
resource "aws_apigatewayv2_integration" "history" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.history.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "history" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "GET /api/rooms/{roomId}/messages"
  target             = "integrations/${aws_apigatewayv2_integration.history.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

# CloudWatch log group for API Gateway access logs
resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${local.prefix}"
  retention_in_days = 14
}
