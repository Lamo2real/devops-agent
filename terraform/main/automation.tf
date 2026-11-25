# -----------------------------------------------------------------------------
# Serverless automation around the agent:
#   alarm -> EventBridge -> Lambda "alarm-trigger" -> DevOps Agent investigation
#   daily schedule -> Lambda "usage-guard" -> CloudWatch metrics -> alarm -> SNS
# Failures land in an SQS dead-letter queue and raise an alarm on the topic.
# -----------------------------------------------------------------------------

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = var.lambda_source_dir
  output_path = "${path.module}/.build/lambda.zip"
}

locals {
  lambda_runtime   = "python3.13"
  usage_namespace  = "DevOpsAgent/Usage"
  smoke_alarm_name = "${var.alarm_name_prefixes[0]}${local.name_prefix}-smoke-test"
}

# --- Alerts -----------------------------------------------------------------------

# Not encrypted with the AWS managed SNS key on purpose: CloudWatch alarms
# cannot publish to topics using that key. Alerts carry no customer data.
resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"
}

data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid     = "CloudWatchAlarms"
    actions = ["sns:Publish"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    resources = [aws_sns_topic.alerts.arn]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

resource "aws_sns_topic_subscription" "alerts_email" {
  for_each  = toset(var.alert_emails)
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${local.name_prefix}-automation-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

data "aws_iam_policy_document" "dlq" {
  statement {
    sid     = "EventBridgeDeadLetters"
    actions = ["sqs:SendMessage"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    resources = [aws_sqs_queue.dlq.arn]
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.alarm_state.arn, aws_cloudwatch_event_rule.usage_schedule.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  policy    = data.aws_iam_policy_document.dlq.json
}

# --- Lambda: alarm -> investigation ---------------------------------------------------

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "alarm_trigger" {
  name                 = "${local.name_prefix}-fn-alarm-trigger"
  description          = "Lambda that starts AWS DevOps Agent investigations from CloudWatch alarms"
  assume_role_policy   = data.aws_iam_policy_document.lambda_trust.json
  permissions_boundary = local.lambda_boundary_arn
}

data "aws_iam_policy_document" "alarm_trigger" {
  statement {
    sid       = "StartInvestigations"
    actions   = ["aidevops:CreateBacklogTask", "aidevops:ListBacklogTasks"]
    resources = [local.agentspace_arn]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.alarm_trigger.arn}:*"]
  }
  statement {
    sid       = "DeadLetters"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dlq.arn]
  }
}

resource "aws_iam_role_policy" "alarm_trigger" {
  name   = "alarm-trigger"
  role   = aws_iam_role.alarm_trigger.id
  policy = data.aws_iam_policy_document.alarm_trigger.json
}

resource "aws_cloudwatch_log_group" "alarm_trigger" {
  name              = "/aws/lambda/${local.name_prefix}-alarm-trigger"
  retention_in_days = 90
}

resource "aws_lambda_function" "alarm_trigger" {
  function_name    = "${local.name_prefix}-alarm-trigger"
  description      = "Starts an AWS DevOps Agent investigation when a symptom alarm goes to ALARM"
  role             = aws_iam_role.alarm_trigger.arn
  runtime          = local.lambda_runtime
  architectures    = ["arm64"]
  handler          = "devops_agent_lambdas.alarm_trigger.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 30
  memory_size      = 256
  # Optional cap (needs an account concurrency quota of at least 10 + value).
  reserved_concurrent_executions = var.alarm_trigger_reserved_concurrency

  environment {
    variables = {
      AGENT_SPACE_ID         = local.agentspace_id
      ASSOCIATION_ID         = awscc_devopsagent_association.monitor.association_id
      INVESTIGATION_PRIORITY = var.investigation_priority
      DEDUP_WINDOW_MINUTES   = tostring(var.dedup_window_minutes)
      ALARM_NAME_PREFIXES    = join(",", var.alarm_name_prefixes)
      LOG_LEVEL              = "INFO"
    }
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  depends_on = [aws_iam_role_policy.alarm_trigger, aws_cloudwatch_log_group.alarm_trigger]
}

resource "aws_lambda_function_event_invoke_config" "alarm_trigger" {
  function_name                = aws_lambda_function.alarm_trigger.function_name
  maximum_retry_attempts       = 2
  maximum_event_age_in_seconds = 3600
}

resource "aws_cloudwatch_event_rule" "alarm_state" {
  name        = "${local.name_prefix}-alarm-to-investigation"
  description = "Symptom alarms entering ALARM start an AWS DevOps Agent investigation"
  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [for p in var.alarm_name_prefixes : { prefix = p }]
      state     = { value = ["ALARM"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "alarm_state" {
  rule = aws_cloudwatch_event_rule.alarm_state.name
  arn  = aws_lambda_function.alarm_trigger.arn
  retry_policy {
    maximum_retry_attempts       = 8
    maximum_event_age_in_seconds = 3600
  }
  dead_letter_config {
    arn = aws_sqs_queue.dlq.arn
  }
}

resource "aws_lambda_permission" "alarm_state" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.alarm_trigger.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.alarm_state.arn
}

# --- Lambda: usage guard -----------------------------------------------------------------

resource "aws_iam_role" "usage_guard" {
  name                 = "${local.name_prefix}-fn-usage-guard"
  description          = "Lambda that publishes AWS DevOps Agent usage as CloudWatch metrics"
  assume_role_policy   = data.aws_iam_policy_document.lambda_trust.json
  permissions_boundary = local.lambda_boundary_arn
}

data "aws_iam_policy_document" "usage_guard" {
  statement {
    sid       = "ReadUsage"
    actions   = ["aidevops:GetAccountUsage"]
    resources = ["*"]
  }
  statement {
    sid       = "PublishMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [local.usage_namespace]
    }
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.usage_guard.arn}:*"]
  }
  statement {
    sid       = "DeadLetters"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dlq.arn]
  }
}

resource "aws_iam_role_policy" "usage_guard" {
  name   = "usage-guard"
  role   = aws_iam_role.usage_guard.id
  policy = data.aws_iam_policy_document.usage_guard.json
}

resource "aws_cloudwatch_log_group" "usage_guard" {
  name              = "/aws/lambda/${local.name_prefix}-usage-guard"
  retention_in_days = 90
}

resource "aws_lambda_function" "usage_guard" {
  function_name    = "${local.name_prefix}-usage-guard"
  description      = "Publishes AWS DevOps Agent monthly usage to CloudWatch"
  role             = aws_iam_role.usage_guard.arn
  runtime          = local.lambda_runtime
  architectures    = ["arm64"]
  handler          = "devops_agent_lambdas.usage_guard.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      METRIC_NAMESPACE = local.usage_namespace
      DIMENSION_VALUE  = local.name_prefix
      LOG_LEVEL        = "INFO"
    }
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  depends_on = [aws_iam_role_policy.usage_guard, aws_cloudwatch_log_group.usage_guard]
}

resource "aws_cloudwatch_event_rule" "usage_schedule" {
  name                = "${local.name_prefix}-usage-guard"
  description         = "Publish AWS DevOps Agent usage every hour"
  schedule_expression = "rate(1 hour)"
}

resource "aws_cloudwatch_event_target" "usage_schedule" {
  rule = aws_cloudwatch_event_rule.usage_schedule.name
  arn  = aws_lambda_function.usage_guard.arn
  retry_policy {
    maximum_retry_attempts       = 2
    maximum_event_age_in_seconds = 3600
  }
  dead_letter_config {
    arn = aws_sqs_queue.dlq.arn
  }
}

resource "aws_lambda_permission" "usage_schedule" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.usage_guard.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.usage_schedule.arn
}

# --- Alarms on the automation itself ----------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "investigation_hours" {
  alarm_name          = "${local.name_prefix}-investigation-hours"
  alarm_description   = "AWS DevOps Agent investigation hours this month reached ${var.monthly_investigation_hours_alert} (about USD 30 per hour)."
  namespace           = local.usage_namespace
  metric_name         = "InvestigationHours"
  dimensions          = { Deployment = local.name_prefix }
  statistic           = "Maximum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = var.monthly_investigation_hours_alert
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "automation_failures" {
  alarm_name          = "${local.name_prefix}-automation-failures"
  alarm_description   = "An alarm could not start an AWS DevOps Agent investigation (see the dead-letter queue and Lambda logs)."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "alarm_trigger_errors" {
  alarm_name          = "${local.name_prefix}-alarm-trigger-errors"
  alarm_description   = "The alarm-trigger Lambda failed."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.alarm_trigger.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "usage_guard_errors" {
  alarm_name          = "${local.name_prefix}-usage-guard-errors"
  alarm_description   = "The usage-guard Lambda failed, so the cost alarm gets no data."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.usage_guard.function_name }
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# --- Smoke test alarm ----------------------------------------------------------------------
# A real symptom-style alarm on a metric nothing publishes. `make smoke-test`
# forces it to ALARM with set-alarm-state, which exercises the whole path.

resource "aws_cloudwatch_metric_alarm" "smoke_test" {
  count               = var.create_smoke_test_alarm ? 1 : 0
  alarm_name          = local.smoke_alarm_name
  alarm_description   = "Smoke test for the AWS DevOps Agent template. Safe to force into ALARM: it starts a short investigation."
  namespace           = "DevOpsAgent/SmokeTest"
  metric_name         = "SyntheticErrors"
  dimensions          = { AgentSpace = local.name_prefix }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
}
