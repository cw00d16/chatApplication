# ---------------------------------------------------------------
# Observability for the @agent feature
#
# Scoped to sendMessage + agent — the two Lambdas involved in an @agent
# turn — not the whole app. Everything here reads the structured JSON logs
# already written by lambda/agent/index.js's `log()` helper and
# lambda/sendMessage/index.js's "agent_triggered" line; see those files for
# the exact field names these metric filters pattern-match against.
# ---------------------------------------------------------------

locals {
  # Claude Opus 5 list pricing, per million tokens — feeds both the
  # dashboard's spend widget and the daily-spend alarm below. Update this
  # if lambda/agent/index.js's AGENT_MODEL env var ever changes models.
  agent_input_price_per_mtok  = 5
  agent_output_price_per_mtok = 25
}

# --- Turn the agent Lambda's structured logs into real CloudWatch metrics ---

resource "aws_cloudwatch_log_metric_filter" "agent_responded" {
  name           = "${local.prefix}-agent-responded"
  log_group_name = aws_cloudwatch_log_group.agent.name
  pattern        = "{ $.event = \"agent_invocation\" && $.outcome = \"responded\" }"

  metric_transformation {
    name      = "InvocationsResponded"
    namespace = "ChatApp/Agent"
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "agent_error" {
  name           = "${local.prefix}-agent-error"
  log_group_name = aws_cloudwatch_log_group.agent.name
  pattern        = "{ $.event = \"agent_invocation\" && $.outcome = \"error\" }"

  metric_transformation {
    name      = "InvocationsError"
    namespace = "ChatApp/Agent"
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "agent_rate_limited" {
  name           = "${local.prefix}-agent-rate-limited"
  log_group_name = aws_cloudwatch_log_group.agent.name
  pattern        = "{ $.event = \"agent_invocation\" && $.outcome = \"rate_limited\" }"

  metric_transformation {
    name      = "InvocationsRateLimited"
    namespace = "ChatApp/Agent"
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "agent_latency" {
  name           = "${local.prefix}-agent-latency"
  log_group_name = aws_cloudwatch_log_group.agent.name
  pattern        = "{ $.event = \"agent_invocation\" && $.latencyMs = \"*\" }"

  metric_transformation {
    name      = "LatencyMs"
    namespace = "ChatApp/Agent"
    value     = "$.latencyMs"
    unit      = "Milliseconds"
  }
}

resource "aws_cloudwatch_log_metric_filter" "agent_input_tokens" {
  name           = "${local.prefix}-agent-input-tokens"
  log_group_name = aws_cloudwatch_log_group.agent.name
  pattern        = "{ $.event = \"agent_invocation\" && $.inputTokens = \"*\" }"

  metric_transformation {
    name      = "InputTokens"
    namespace = "ChatApp/Agent"
    value     = "$.inputTokens"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "agent_output_tokens" {
  name           = "${local.prefix}-agent-output-tokens"
  log_group_name = aws_cloudwatch_log_group.agent.name
  pattern        = "{ $.event = \"agent_invocation\" && $.outputTokens = \"*\" }"

  metric_transformation {
    name      = "OutputTokens"
    namespace = "ChatApp/Agent"
    value     = "$.outputTokens"
    unit      = "Count"
  }
}

# A spike here is the signal to look for — it means Claude's own safety
# classifiers are declining requests, which on a public chat room usually
# means someone is probing the guardrails rather than an ordinary refusal.
resource "aws_cloudwatch_log_metric_filter" "agent_refusals" {
  name           = "${local.prefix}-agent-refusals"
  log_group_name = aws_cloudwatch_log_group.agent.name
  pattern        = "{ $.event = \"agent_invocation\" && $.stopReason = \"refusal\" }"

  metric_transformation {
    name      = "Refusals"
    namespace = "ChatApp/Agent"
    value     = "1"
    unit      = "Count"
  }
}

# --- SNS topic + email subscription for alarms ---

resource "aws_sns_topic" "agent_alerts" {
  name = "${local.prefix}-agent-alerts"
}

# SNS emails a one-time confirmation link to alert_email after apply — the
# subscription stays PendingConfirmation (and won't deliver anything) until
# that link is clicked.
resource "aws_sns_topic_subscription" "agent_alerts_email" {
  topic_arn = aws_sns_topic.agent_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --- Alarms ---

resource "aws_cloudwatch_metric_alarm" "agent_error_rate" {
  alarm_name          = "${local.prefix}-agent-error-rate"
  alarm_description   = "3+ agent invocations failed (Claude API error, secret fetch failure, etc.) in a 5-minute window"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = 3
  treat_missing_data  = "notBreaching"

  metric_name = "InvocationsError"
  namespace   = "ChatApp/Agent"
  period      = 300
  statistic   = "Sum"

  alarm_actions = [aws_sns_topic.agent_alerts.arn]
  ok_actions    = [aws_sns_topic.agent_alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "agent_daily_spend" {
  alarm_name          = "${local.prefix}-agent-daily-spend"
  alarm_description   = "Estimated daily Claude spend (list pricing, input+output tokens) exceeded $${var.daily_spend_alert_threshold_usd}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = var.daily_spend_alert_threshold_usd
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.agent_alerts.arn]
  ok_actions    = [aws_sns_topic.agent_alerts.arn]

  metric_query {
    id          = "input_tokens"
    return_data = false
    metric {
      metric_name = "InputTokens"
      namespace   = "ChatApp/Agent"
      period      = 86400
      stat        = "Sum"
    }
  }

  metric_query {
    id          = "output_tokens"
    return_data = false
    metric {
      metric_name = "OutputTokens"
      namespace   = "ChatApp/Agent"
      period      = 86400
      stat        = "Sum"
    }
  }

  metric_query {
    id          = "estimated_spend"
    expression  = "(input_tokens/1000000*${local.agent_input_price_per_mtok})+(output_tokens/1000000*${local.agent_output_price_per_mtok})"
    label       = "Estimated daily spend (USD)"
    return_data = true
  }
}

# --- Dashboard ---

resource "aws_cloudwatch_dashboard" "agent" {
  dashboard_name = "${local.prefix}-agent"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Agent Invocations by Outcome"
          view   = "timeSeries"
          region = var.aws_region
          period = 300
          stat   = "Sum"
          metrics = [
            ["ChatApp/Agent", "InvocationsResponded", { label = "Responded" }],
            ["ChatApp/Agent", "InvocationsError", { label = "Error" }],
            ["ChatApp/Agent", "InvocationsRateLimited", { label = "Rate limited" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Agent Latency"
          view   = "timeSeries"
          region = var.aws_region
          period = 300
          metrics = [
            ["ChatApp/Agent", "LatencyMs", { stat = "p50", label = "p50" }],
            ["ChatApp/Agent", "LatencyMs", { stat = "p99", label = "p99" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Estimated Claude Spend (USD)"
          view   = "timeSeries"
          region = var.aws_region
          period = 86400
          metrics = [
            [{ id = "e1", label = "Estimated spend ($)", expression = "(m1/1000000*${local.agent_input_price_per_mtok})+(m2/1000000*${local.agent_output_price_per_mtok})" }],
            ["ChatApp/Agent", "InputTokens", { id = "m1", stat = "Sum", visible = false }],
            ["ChatApp/Agent", "OutputTokens", { id = "m2", stat = "Sum", visible = false }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Refusals (possible injection probing)"
          view    = "timeSeries"
          region  = var.aws_region
          period  = 3600
          stat    = "Sum"
          metrics = [["ChatApp/Agent", "Refusals"]]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 24
        height = 6
        properties = {
          title  = "Agent Lambda Health"
          view   = "timeSeries"
          region = var.aws_region
          period = 300
          stat   = "Sum"
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.agent.function_name],
            ["AWS/Lambda", "Throttles", "FunctionName", aws_lambda_function.agent.function_name],
            ["AWS/Lambda", "ConcurrentExecutions", "FunctionName", aws_lambda_function.agent.function_name, { stat = "Maximum" }],
          ]
        }
      },
    ]
  })
}
