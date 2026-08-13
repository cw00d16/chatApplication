# ---------------------------------------------------------------
# CloudFront — CDN for the frontend + HTTP API caching
#
# The WebSocket API is NOT behind CloudFront — the browser connects
# to its wss:// endpoint directly. Only the HTTP API (rooms/history)
# and the static frontend go through CloudFront.
# ---------------------------------------------------------------

# Origin Access Control — modern replacement for OAI
resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${local.prefix}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Cache policy for static assets (long TTL)
resource "aws_cloudfront_cache_policy" "static" {
  name        = "${local.prefix}-static-cache"
  min_ttl     = 0
  default_ttl = 86400    # 1 day
  max_ttl     = 31536000 # 1 year

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config { cookie_behavior = "none" }
    headers_config { header_behavior = "none" }
    query_strings_config { query_string_behavior = "none" }
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}

# Cache policy for API (no caching — always fresh)
resource "aws_cloudfront_cache_policy" "api" {
  name        = "${local.prefix}-api-no-cache"
  min_ttl     = 0
  default_ttl = 0
  max_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config { cookie_behavior = "none" }
    headers_config { header_behavior = "none" }
    query_strings_config { query_string_behavior = "none" }
  }
}

# Origin request policy — forward auth header to API
resource "aws_cloudfront_origin_request_policy" "api" {
  name = "${local.prefix}-api-origin-request"

  cookies_config { cookie_behavior = "none" }
  headers_config {
    header_behavior = "whitelist"
    headers {
      items = ["Authorization", "Content-Type"]
    }
  }
  query_strings_config { query_string_behavior = "none" }
}

locals {
  s3_origin_id  = "S3-${aws_s3_bucket.frontend.bucket}"
  api_origin_id = "APIGW-${aws_apigatewayv2_api.main.id}"

  # Strip the https:// prefix from the API endpoint for CloudFront
  api_domain = replace(aws_apigatewayv2_api.main.api_endpoint, "https://", "")
}

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100" # US, Canada, Europe only — cheapest
  aliases             = local.use_custom_domain ? [var.domain_name] : []

  # --- Origin 1: S3 for static React assets ---
  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = local.s3_origin_id
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  # --- Origin 2: HTTP API Gateway for rooms/history ---
  origin {
    domain_name = local.api_domain
    origin_id   = local.api_origin_id
    origin_path = "/${aws_apigatewayv2_stage.main.name}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Default behavior — serve from S3
  default_cache_behavior {
    target_origin_id       = local.s3_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = aws_cloudfront_cache_policy.static.id
    compress               = true
  }

  # /api/* — route to HTTP API Gateway, no caching
  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = local.api_origin_id
    viewer_protocol_policy   = "https-only"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = aws_cloudfront_cache_policy.api.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.api.id
    compress                 = true
  }

  # React Router — return index.html for all unknown paths (SPA routing)
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }
  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = !local.use_custom_domain
    acm_certificate_arn            = local.use_custom_domain ? aws_acm_certificate.main[0].arn : null
    ssl_support_method             = local.use_custom_domain ? "sni-only" : null
    minimum_protocol_version       = local.use_custom_domain ? "TLSv1.2_2021" : null
  }
}

# Optional: ACM cert for custom domain (must be in us-east-1)
resource "aws_acm_certificate" "main" {
  count             = local.use_custom_domain ? 1 : 0
  provider          = aws.us_east_1
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}
