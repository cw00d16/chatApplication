variable "aws_region" {
  description = "Primary AWS region"
  type        = string
  default     = "us-east-2"
}

variable "project_name" {
  description = "Project name used in resource naming"
  type        = string
  default     = "chat-application"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "prod"
}

variable "domain_name" {
  description = "Your custom domain (e.g. chat.example.com). Leave empty to use CloudFront default domain."
  type        = string
  default     = ""
}

variable "github_repo" {
  description = "GitHub repo in owner/repo format (e.g. cw00d16/chatApplication). Used for OIDC trust."
  type        = string
}

variable "lambda_memory_mb" {
  description = "Memory allocated to each Lambda function"
  type        = number
  default     = 256
}

variable "lambda_timeout_seconds" {
  description = "Lambda function timeout"
  type        = number
  default     = 10
}

variable "dynamodb_billing_mode" {
  description = "DynamoDB billing mode: PAY_PER_REQUEST or PROVISIONED"
  type        = string
  default     = "PAY_PER_REQUEST"
}

locals {
  prefix            = "chatapp-${var.environment}"
  use_custom_domain = var.domain_name != ""
}
