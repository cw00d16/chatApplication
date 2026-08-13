# ---------------------------------------------------------------
# API Gateway v2 (WebSocket API) — real-time chat transport
#
# Browsers can't set a custom Authorization header on the WebSocket
# handshake, so the Cognito access token is passed as a query string
# param (?token=...) and verified inside the $connect Lambda instead
# of via a built-in JWT authorizer (WebSocket APIs don't support one).
# ---------------------------------------------------------------

resource "aws_apigatewayv2_api" "chat" {
  name                       = "${local.prefix}-chat-ws"
  protocol_type              = "WEBSOCKET"
  route_selection_expression = "$request.body.action"
}

resource "aws_apigatewayv2_stage" "chat" {
  api_id      = aws_apigatewayv2_api.chat.id
  name        = var.environment
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.chat_api_gateway.arn
    format          = "$context.requestId $context.eventType $context.connectionId $context.status"
  }

  default_route_settings {
    throttling_burst_limit = 100
    throttling_rate_limit  = 50
  }
}

resource "aws_cloudwatch_log_group" "chat_api_gateway" {
  name              = "/aws/apigateway/${local.prefix}-chat-ws"
  retention_in_days = 14
}

# --- $connect — verifies the Cognito token, creates the connection record ---
resource "aws_apigatewayv2_integration" "connect" {
  api_id                 = aws_apigatewayv2_api.chat.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.connect.invoke_arn
  payload_format_version = "1.0" # WEBSOCKET only supports 1.0
}

resource "aws_apigatewayv2_route" "connect" {
  api_id    = aws_apigatewayv2_api.chat.id
  route_key = "$connect"
  target    = "integrations/${aws_apigatewayv2_integration.connect.id}"
}

resource "aws_lambda_permission" "connect" {
  statement_id  = "AllowChatWebSocket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.connect.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.chat.execution_arn}/*/*"
}

# --- $disconnect — removes the connection record ---
resource "aws_apigatewayv2_integration" "disconnect" {
  api_id                 = aws_apigatewayv2_api.chat.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.disconnect.invoke_arn
  payload_format_version = "1.0"
}

resource "aws_apigatewayv2_route" "disconnect" {
  api_id    = aws_apigatewayv2_api.chat.id
  route_key = "$disconnect"
  target    = "integrations/${aws_apigatewayv2_integration.disconnect.id}"
}

resource "aws_lambda_permission" "disconnect" {
  statement_id  = "AllowChatWebSocket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.disconnect.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.chat.execution_arn}/*/*"
}

# --- joinRoom — { action: "joinRoom", roomId } ---
resource "aws_apigatewayv2_integration" "join_room" {
  api_id                 = aws_apigatewayv2_api.chat.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.join_room.invoke_arn
  payload_format_version = "1.0"
}

resource "aws_apigatewayv2_route" "join_room" {
  api_id    = aws_apigatewayv2_api.chat.id
  route_key = "joinRoom"
  target    = "integrations/${aws_apigatewayv2_integration.join_room.id}"
}

resource "aws_lambda_permission" "join_room" {
  statement_id  = "AllowChatWebSocket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.join_room.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.chat.execution_arn}/*/*"
}

# --- sendMessage — { action: "sendMessage", body }, fans out to the room ---
resource "aws_apigatewayv2_integration" "send_message" {
  api_id                 = aws_apigatewayv2_api.chat.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.send_message.invoke_arn
  payload_format_version = "1.0"
}

resource "aws_apigatewayv2_route" "send_message" {
  api_id    = aws_apigatewayv2_api.chat.id
  route_key = "sendMessage"
  target    = "integrations/${aws_apigatewayv2_integration.send_message.id}"
}

resource "aws_lambda_permission" "send_message" {
  statement_id  = "AllowChatWebSocket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.send_message.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.chat.execution_arn}/*/*"
}
