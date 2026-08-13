# ---------------------------------------------------------------
# Cognito — authentication
# ---------------------------------------------------------------

resource "aws_cognito_user_pool" "main" {
  name = "${local.prefix}-users"

  # Users sign in with email
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  # MFA — optional for users (they can enable TOTP)
  mfa_configuration = "OPTIONAL"

  software_token_mfa_configuration {
    enabled = true
  }

  # Email verification
  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "Your verification code"
    email_message        = "Your verification code is {####}"
  }

  # Account recovery
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Schema — standard attributes
  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
  }

  # Auto-delete unconfirmed accounts after 7 days
  user_pool_add_ons {
    advanced_security_mode = "AUDIT"
  }
}

# App client used by the React frontend
resource "aws_cognito_user_pool_client" "frontend" {
  name         = "${local.prefix}-frontend-client"
  user_pool_id = aws_cognito_user_pool.main.id

  # No client secret — public client (browser app can't keep secrets)
  generate_secret = false

  # Token validity
  access_token_validity  = 1  # hours
  id_token_validity      = 1  # hours
  refresh_token_validity = 30 # days

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  # Auth flows — SRP is the secure browser-compatible flow
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_PASSWORD_AUTH" # convenient for testing; remove in high-security apps
  ]

  # Prevent user existence errors from leaking (don't say "user not found")
  prevent_user_existence_errors = "ENABLED"

  # Allowed OAuth scopes (needed if you add social login later)
  supported_identity_providers = ["COGNITO"]
}

# Cognito domain for the hosted UI (optional, useful for social login later)
resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${local.prefix}-auth-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.main.id
}
