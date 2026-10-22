# Three publishers: the availability Lambda (IAM-authorized, same account),
# EventBridge's backup-failure rule (backup_alerts.tf), and the disk alarm
# (disk_alarm.tf); the last two publish as service principals, not IAM
# identities, so they need the topic policy below.
resource "aws_sns_topic" "alerts" {
  name = "gramps-web-alerts"

  tags = {
    Name = "gramps-web-alerts"
  }
}

# EventBridge and CloudWatch alarms publish to SNS as service principals, so
# the topic policy has to allow them. Scoped to this account's resources. Same
# shape as data.aws_iam_policy_document.audit_topic (modules/audit/monitor.tf).
data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid       = "AllowEventBridgePublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "AllowDiskAlarmPublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudwatch:${data.aws_region.current.region}:${local.account_id}:alarm:gramps-web-disk-used"]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

# Pending until the confirmation email is clicked; nothing is delivered before.
resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# "Down" = 2 of the last 3 minutes failed; "recovered" = 3 clean minutes.
# Outages shorter than ~2 min never alarm (deliberate: a reclaim with instant
# replacement capacity still takes 4+ min of boot/deploy, so every real Spot
# outage is caught, while single-probe network blips are not). Missing data
# is breaching: if the metric source itself stops reporting, that is
# indistinguishable from "unknown" and should be loud.
resource "aws_cloudwatch_metric_alarm" "site_down" {
  alarm_name          = "gramps-web-site-down"
  alarm_description   = "Cannot reach https://${var.primary_domain}/."
  namespace           = "GrampsWeb"
  metric_name         = "SiteUp"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  # Notifications go through the Lambda (via the state-change rule below) so
  # they can carry cause + duration; no direct alarm actions.

  tags = {
    Name = "gramps-web-site-down"
  }
}

resource "aws_cloudwatch_event_rule" "alarm_state" {
  name        = "gramps-web-availability-alarm-state"
  description = "Routes site-down alarm transitions to the availability Lambda for enriched DOWN/RECOVERED emails."
  # Disabled while the env sleeps: the alarm breaches by design (no canary
  # data) and must not email anyone about it.
  state = var.active ? "ENABLED" : "DISABLED"

  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [aws_cloudwatch_metric_alarm.site_down.alarm_name]
      state = {
        value = ["ALARM", "OK"]
      }
    }
  })

  tags = {
    Name = "gramps-web-availability-alarm-state"
  }
}

resource "aws_cloudwatch_event_target" "alarm_state" {
  rule      = aws_cloudwatch_event_rule.alarm_state.name
  target_id = "availability-lambda"
  arn       = aws_lambda_function.availability.arn
}

resource "aws_lambda_permission" "alarm_state" {
  statement_id  = "AllowAlarmStateRule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.availability.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.alarm_state.arn
}
