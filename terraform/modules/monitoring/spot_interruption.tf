# Spot churn signal. Every reclaim emits an "EC2 Spot Instance Interruption
# Warning" ~2 min before the instance dies. Two targets:
#   - the availability Lambda, which records the doomed instance's details so
#     the upcoming outage gets attributed to the reclaim (the DOWN email
#     carries this)
#   - a log group, the queryable raw history of interruptions
#
# Assumes this is the only Spot workload in the account/region: the pattern
# matches all interruption warnings, not just this ASG's instances. Add a
# detail filter if that stops being true.

resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "gramps-web-spot-interruption"
  description = "EC2 Spot interruption warnings (Spot churn signal)."

  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Spot Instance Interruption Warning"]
  })

  tags = {
    Name = "gramps-web-spot-interruption"
  }
}

resource "aws_cloudwatch_event_target" "spot_lambda" {
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
  target_id = "availability-lambda"
  arn       = aws_lambda_function.availability.arn
}

resource "aws_lambda_permission" "spot_interruption" {
  statement_id  = "AllowSpotInterruptionRule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.availability.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.spot_interruption.arn
}

# --- CloudWatch Logs: queryable history --------------------------------------
# The log-group name must start with /aws/events/ to be a valid EventBridge
# target. retention_in_days = 365 gives a year of trend for a few bytes/event.

resource "aws_cloudwatch_log_group" "spot_interruptions" {
  name              = "/aws/events/gramps-web-spot-interruptions"
  retention_in_days = 365

  tags = {
    Name = "gramps-web-spot-interruptions"
  }
}

data "aws_iam_policy_document" "spot_log_delivery" {
  statement {
    sid    = "AllowEventBridgeToLog"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "delivery.logs.amazonaws.com"]
    }
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.spot_interruptions.arn}:*"]
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.spot_interruption.arn]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "spot_log_delivery" {
  policy_name     = "gramps-web-spot-eventbridge"
  policy_document = data.aws_iam_policy_document.spot_log_delivery.json
}

# Full event JSON, so Logs Insights can aggregate (e.g. count per week).
resource "aws_cloudwatch_event_target" "spot_log" {
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
  target_id = "cloudwatch-logs"
  arn       = aws_cloudwatch_log_group.spot_interruptions.arn
}
