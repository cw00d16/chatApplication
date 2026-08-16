# ---------------------------------------------------------------
# Secrets Manager — Anthropic API key
#
# Deliberately no aws_secretsmanager_secret_version resource here: putting
# the key value in a Terraform resource means it's stored in plan output
# and state. Populate the secret once, out-of-band, after `terraform
# apply` creates it:
#
#   aws secretsmanager put-secret-value \
#     --secret-id chatapp-prod-anthropic-api-key \
#     --secret-string "sk-ant-..."
#
# Rotate the same way; the agent Lambda re-reads it from Secrets Manager
# on its next cold start (it caches the value in memory across warm
# invocations — see lambda/agent/index.js).
# ---------------------------------------------------------------

resource "aws_secretsmanager_secret" "anthropic_api_key" {
  name        = "${local.prefix}-anthropic-api-key"
  description = "Anthropic API key used by the @agent Lambda"
}
