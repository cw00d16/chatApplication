# ---------------------------------------------------------------
# GitHub Actions CI/CD — OIDC-based IAM role
#
# This lets GitHub Actions assume an AWS role without storing
# long-lived AWS keys as GitHub secrets. Much more secure.
# ---------------------------------------------------------------

# OIDC provider — trust GitHub's token service
#
# This is an account-wide singleton (one provider per issuer URL per AWS
# account), and urlShortener's Terraform already created it. Reference it
# instead of trying to create a second one.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# IAM role that GitHub Actions assumes via OIDC
resource "aws_iam_role" "github_actions" {
  name = "${local.prefix}-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = data.aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # AWS requires `sub` (or `job_workflow_ref`) itself to be scoped —
          # matching only the `repository` claim isn't accepted. GitHub now
          # embeds immutable numeric IDs into `sub`
          # (repo:owner@ownerId/name@repoId:ref:...) instead of the classic
          # repo:owner/name:ref:... format, so match both shapes.
          "token.actions.githubusercontent.com:sub" = [
            "repo:${var.github_repo}:*",
            "repo:${local.github_owner}@*/${local.github_name}@*:*",
          ]
        }
      }
    }]
  })
}

# Policy: deploy frontend to S3 + invalidate CloudFront
resource "aws_iam_role_policy" "github_frontend" {
  name = "${local.prefix}-github-frontend"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Deploy"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.frontend.arn,
          "${aws_s3_bucket.frontend.arn}/*"
        ]
      },
      {
        Sid    = "CloudFrontInvalidate"
        Effect = "Allow"
        Action = [
          "cloudfront:CreateInvalidation",
          "cloudfront:GetInvalidation"
        ]
        Resource = aws_cloudfront_distribution.frontend.arn
      }
    ]
  })
}

# Policy: deploy Lambda functions
resource "aws_iam_role_policy" "github_lambda" {
  name = "${local.prefix}-github-lambda"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "LambdaDeploy"
      Effect = "Allow"
      Action = [
        "lambda:UpdateFunctionCode",
        "lambda:GetFunction",
        "lambda:PublishVersion",
        "lambda:UpdateAlias"
      ]
      Resource = [
        aws_lambda_function.connect.arn,
        aws_lambda_function.disconnect.arn,
        aws_lambda_function.join_room.arn,
        aws_lambda_function.send_message.arn,
        aws_lambda_function.rooms.arn,
        aws_lambda_function.history.arn
      ]
    }]
  })
}
