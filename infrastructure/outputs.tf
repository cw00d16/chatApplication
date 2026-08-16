output "cloudfront_url" {
  description = "CloudFront distribution URL for the frontend"
  value       = "https://${aws_cloudfront_distribution.frontend.domain_name}"
}

output "api_gateway_url" {
  description = "HTTP API invoke URL (rooms/history)"
  value       = "${aws_apigatewayv2_api.main.api_endpoint}/${aws_apigatewayv2_stage.main.name}"
}

output "websocket_url" {
  description = "WebSocket API invoke URL (real-time chat)"
  value       = "${aws_apigatewayv2_api.chat.api_endpoint}/${aws_apigatewayv2_stage.chat.name}"
}

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.main.id
}

output "cognito_client_id" {
  description = "Cognito App Client ID for the frontend"
  value       = aws_cognito_user_pool_client.frontend.id
}

output "s3_bucket_name" {
  description = "S3 bucket hosting the React frontend"
  value       = aws_s3_bucket.frontend.bucket
}

output "connections_table_name" {
  description = "DynamoDB connections table name"
  value       = aws_dynamodb_table.connections.name
}

output "rooms_table_name" {
  description = "DynamoDB rooms table name"
  value       = aws_dynamodb_table.rooms.name
}

output "messages_table_name" {
  description = "DynamoDB messages table name"
  value       = aws_dynamodb_table.messages.name
}

output "anthropic_api_key_secret_name" {
  description = "Secrets Manager secret to populate with `aws secretsmanager put-secret-value` (see infrastructure/secrets.tf)"
  value       = aws_secretsmanager_secret.anthropic_api_key.name
}

output "github_actions_role_arn" {
  description = "IAM role ARN for GitHub Actions to assume"
  value       = aws_iam_role.github_actions.arn
}

output "frontend_env_vars" {
  description = "Environment variables to set in your React app"
  value = {
    REACT_APP_API_URL           = "${aws_apigatewayv2_api.main.api_endpoint}/${aws_apigatewayv2_stage.main.name}"
    REACT_APP_WEBSOCKET_URL     = "${aws_apigatewayv2_api.chat.api_endpoint}/${aws_apigatewayv2_stage.chat.name}"
    REACT_APP_COGNITO_USER_POOL = aws_cognito_user_pool.main.id
    REACT_APP_COGNITO_CLIENT_ID = aws_cognito_user_pool_client.frontend.id
    REACT_APP_COGNITO_REGION    = var.aws_region
  }
}
