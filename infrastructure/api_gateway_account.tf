# ---------------------------------------------------------------
# API Gateway account settings — CloudWatch Logs role
#
# WebSocket API stages (unlike HTTP API stages) refuse to enable
# access logging unless a CloudWatch role ARN is set at the account
# level for the region. This is an account-wide singleton — applying
# it here is safe even if another project's Terraform runs alongside
# it, since it just sets the same account setting to the same value.
# ---------------------------------------------------------------

resource "aws_iam_role" "api_gateway_cloudwatch" {
  name = "${local.prefix}-apigateway-cloudwatch"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "apigateway.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "api_gateway_cloudwatch" {
  role       = aws_iam_role.api_gateway_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "main" {
  cloudwatch_role_arn = aws_iam_role.api_gateway_cloudwatch.arn
}
