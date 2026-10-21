# One Lambda handles the whole availability story: the per-minute canary
# probe, Spot-interruption context capture, and DOWN/RECOVERED notifications.
# Splitting it into three functions would triple the IAM/wiring for a few
# hundred lines of stdlib Python that share state and helpers.

locals {
  metric_namespace = "GrampsWeb"
  site_url         = "https://${var.primary_domain}/"
  account_id       = data.aws_caller_identity.current.account_id
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "archive_file" "availability" {
  type        = "zip"
  source_file = "${path.module}/lambda/availability.py"
  output_path = "${path.module}/lambda/availability.zip"
}

resource "aws_lambda_function" "availability" {
  function_name    = "gramps-web-availability"
  role             = aws_iam_role.availability.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "availability.handler"
  filename         = data.archive_file.availability.output_path
  source_code_hash = data.archive_file.availability.output_base64sha256
  memory_size      = 128
  timeout          = 60 # probe is 8s; the episode path makes about eight sequential history calls, each bounded at 8s

  # The schedule can invoke within seconds of creation; without this the
  # runtime auto-creates the log group first and Terraform's create conflicts.
  depends_on = [aws_cloudwatch_log_group.lambda]

  environment {
    variables = {
      SITE_URL                       = local.site_url
      ASG_NAME                       = var.asg_name
      SNS_TOPIC_ARN                  = aws_sns_topic.alerts.arn
      STATE_PARAM                    = aws_ssm_parameter.state.name
      EPISODES_LOG_GROUP             = aws_cloudwatch_log_group.episodes.name
      EPISODES_LOG_STREAM            = aws_cloudwatch_log_stream.episodes.name
      CHANGES_LOG_STREAM             = aws_cloudwatch_log_stream.changes.name
      METRIC_NAMESPACE               = local.metric_namespace
      CODEDEPLOY_APP_NAME            = var.codedeploy_app_name
      CODEDEPLOY_DEPLOYMENT_GROUP    = var.codedeploy_deployment_group_name
      LAST_RIGHTSIZE_PARAM           = var.last_rightsize_param_name
      LAST_HEALTH_WATCHDOG_PARAM     = var.last_health_watchdog_param_name
      LAST_BACKUP_SNAPSHOT_PARAM     = var.last_backup_snapshot_param_name
      DELIBERATE_DEPLOYMENT_CREATORS = join(",", var.deliberate_deployment_creators)
    }
  }

  tags = {
    Name = "gramps-web-availability"
  }
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/gramps-web-availability"
  retention_in_days = 30

  tags = {
    Name = "gramps-web-availability-lambda"
  }
}

# Cross-conversation memory: one JSON doc holding the last Spot interruption
# (for cause attribution) and the open outage. Standard parameter = free.
# The Lambda owns the value after creation.
resource "aws_ssm_parameter" "state" {
  name  = "/gramps-web/availability/state"
  type  = "String"
  value = "{}"

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Name = "gramps-web-availability-state"
  }
}

# One JSON line per completed outage episode (start, end, duration, cause,
# old/new instance). This is the long-term "what is Spot costing me" record;
# the saved Logs Insights queries aggregate it.
resource "aws_cloudwatch_log_group" "episodes" {
  name              = "/gramps-web/availability-episodes"
  retention_in_days = 365

  tags = {
    Name = "gramps-web-availability-episodes"
  }
}

# Pre-created so the Lambda only needs PutLogEvents (no token required since
# the 2023 CloudWatch Logs API change).
resource "aws_cloudwatch_log_stream" "episodes" {
  name           = "episodes"
  log_group_name = aws_cloudwatch_log_group.episodes.name
}

# One JSON line per completed deployment or instance refresh (see changes.tf),
# kept apart from the episodes so a change is recorded whether or not it
# caused downtime.
resource "aws_cloudwatch_log_stream" "changes" {
  name           = "changes"
  log_group_name = aws_cloudwatch_log_group.episodes.name
}

# --- canary schedule -----------------------------------------------------------

resource "aws_cloudwatch_event_rule" "canary" {
  name                = "gramps-web-availability-canary"
  description         = "Per-minute end-to-end probe of the site."
  schedule_expression = "rate(1 minute)"
  # Asleep env: no probes. The alarm goes to (suppressed) ALARM via
  # treat_missing_data = breaching, which is what makes the wake path honest:
  # re-enabling the canary drives ALARM -> OK and one RECOVERED email once the
  # site actually serves again.
  state = var.active ? "ENABLED" : "DISABLED"

  tags = {
    Name = "gramps-web-availability-canary"
  }
}

resource "aws_cloudwatch_event_target" "canary" {
  rule      = aws_cloudwatch_event_rule.canary.name
  target_id = "availability-lambda"
  arn       = aws_lambda_function.availability.arn
}

resource "aws_lambda_permission" "canary" {
  statement_id  = "AllowCanarySchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.availability.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.canary.arn
}

# --- IAM -------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "availability" {
  name               = "gramps-web-availability"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = {
    Name = "gramps-web-availability"
  }
}

data "aws_iam_policy_document" "availability" {
  statement {
    sid     = "OwnLogs"
    effect  = "Allow"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "${aws_cloudwatch_log_group.lambda.arn}:*",
    ]
  }

  statement {
    sid       = "EpisodeLog"
    effect    = "Allow"
    actions   = ["logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.episodes.arn}:*"]
  }

  statement {
    sid       = "PutMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [local.metric_namespace]
    }
  }

  # GetMetricData supports neither resource-level scoping nor the namespace
  # condition key, so it is a separate "*" statement. Reads SiteUp back at alarm
  # time to recover the true outage edges.
  statement {
    sid       = "ReadMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:GetMetricData"]
    resources = ["*"]
  }

  # Describe* calls don't support resource-level scoping.
  statement {
    sid    = "DescribeInfra"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeSpotPriceHistory",
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeInstanceRefreshes",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "State"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = [aws_ssm_parameter.state.arn]
  }

  # Markers: read-only. The instance role (watchdogs) and the operator
  # (backup.sh) own the write side; see watchdog_markers.tf. Cause attribution
  # (availability.py's classify_cause()) reads these back.
  statement {
    sid       = "Markers"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [var.last_rightsize_param_arn, var.last_health_watchdog_param_arn, var.last_backup_snapshot_param_arn]
  }

  # Deploy cause attribution: list/read this app's own deployment history to
  # check whether one was created around the outage start. ListDeployments is
  # scopable to the deployment group; BatchGetDeployments is scoped by
  # individual deployment (arn:...:deployment:<id>), and deployment IDs aren't
  # known ahead of time, so that half is wildcarded within this account/region
  # rather than opened up to "*". Matches status/iam.tf's identical grant for
  # the status page's own deployment panel.
  statement {
    sid    = "CodeDeployReadOnly"
    effect = "Allow"
    actions = [
      "codedeploy:ListDeployments",
      "codedeploy:BatchGetDeployments",
      "codedeploy:GetDeployment",
    ]
    resources = [
      "arn:aws:codedeploy:${data.aws_region.current.region}:${local.account_id}:deploymentgroup:${var.codedeploy_app_name}/${var.codedeploy_deployment_group_name}",
      "arn:aws:codedeploy:${data.aws_region.current.region}:${local.account_id}:deployment:*",
    ]
  }

  statement {
    sid       = "Notify"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_iam_role_policy" "availability" {
  name   = "gramps-web-availability"
  role   = aws_iam_role.availability.id
  policy = data.aws_iam_policy_document.availability.json
}
