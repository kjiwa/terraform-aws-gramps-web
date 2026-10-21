# Status Lambda behind a Function URL that CloudFront reaches via OAC (see
# edge/status.tf for that half). See the `status` variable in
# roots/stack/variables.tf for what the page shows, who can see it, and what
# public_reliability does; see lambda/status.py's docstring for the code
# structure. Gramps Web's own users/roles are the sole identity source for
# the gated routes -- lambda/status.py forwards the caller's token to GET
# /api/users/-/ on the site itself, so there is no second user directory.

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  # Hardcoded rather than threaded through as a variable: these are the same
  # literals the monitoring module uses for its episode log group and the one
  # stream it writes every episode to (lambda.tf there), and monitoring
  # exports outputs for neither. Two modules agreeing on constant strings is
  # simpler than a cross-module wire for names that only ever change alongside
  # this file anyway.
  episodes_log_group  = "/gramps-web/availability-episodes"
  episodes_log_stream = "episodes"
  changes_log_stream  = "changes"

  # The EventBridge target log group of the Spot interruption rule
  # (monitoring/spot_interruption.tf), one JSON event per warning.
  spot_interruptions_log_group = "/aws/events/gramps-web-spot-interruptions"
}

# output_path lives outside lambda/ to avoid recursive packaging on re-apply.
# source_file packages only the runtime handler.
data "archive_file" "status" {
  type        = "zip"
  output_path = "${path.module}/dist/status.zip"
  source_file = "${path.module}/lambda/status.py"
}

resource "aws_lambda_function" "status" {
  function_name    = "gramps-web-status"
  role             = aws_iam_role.status.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "status.handler"
  filename         = data.archive_file.status.output_path
  source_code_hash = data.archive_file.status.output_base64sha256
  # Lambda scales vCPU with memory; the panel fan-out in lambda/status.py is
  # CPU-bound waiting on network I/O across threads, so roughly 4x the CPU at
  # 512 MB cuts wall time by close to the same factor, leaving GB-seconds (and
  # so cost) close to a wash while cold-start import time drops too.
  memory_size = 512
  timeout     = 20

  # Capped well below the account's concurrency pool: this Lambda shares that
  # pool with the availability canary (modules/monitoring), which runs
  # rate(1 minute) and is the sole producer of the SiteUp metric this page
  # (and /_status/public) reports, so a flood against this function could
  # throttle the canary and corrupt the uptime metric. 10 covers legitimate
  # traffic bursts while leaving unreserved concurrency comfortably above
  # AWS's 100-minimum floor. Request-path caches in lambda/status.py and
  # CloudFront caching in edge/cloudfront_primary.tf provide the primary abuse bound.
  reserved_concurrent_executions = 10

  # CloudFront can invoke within seconds of creation; without this the runtime
  # auto-creates the log group first and Terraform's create conflicts.
  depends_on = [aws_cloudwatch_log_group.status_lambda]

  environment {
    variables = {
      SITE_URL                       = "https://${var.primary_domain}"
      MIN_ROLE                       = var.min_role
      ASG_NAME                       = var.asg_name
      CODEDEPLOY_APP_NAME            = var.codedeploy_app_name
      CODEDEPLOY_DEPLOYMENT_GROUP    = var.codedeploy_deployment_group_name
      DELIBERATE_DEPLOYMENT_CREATORS = join(",", var.deliberate_deployment_creators)
      CODEPIPELINE_NAME              = var.codepipeline_name
      SOURCE_REPO                    = var.source_repo
      ECR_REPO_NAME                  = var.ecr_repository_name
      EBS_VOLUME_ID                  = var.ebs_volume_id
      MEDIA_BUCKET_NAME              = var.media_bucket_name
      BACKUP_VAULT_NAME              = var.backup_vault_name
      BACKUP_MODE                    = var.backup_mode
      BACKUP_SCHEDULE                = var.backup_schedule
      BACKUP_RETENTION_DAYS          = tostring(var.backup_retention_days)
      BACKUP_RESOURCE_COUNT          = tostring(var.backup_resource_count)
      BACKUP_REMOTE_RETENTION_DAYS   = tostring(var.backup_remote_retention_days)
      BACKUP_REGION                  = var.backup_region
      BACKUP_COPY_VAULT_ARN          = var.backup_copy_vault_arn
      BACKUP_DEST_READER_ROLE_ARN    = var.backup_dest_reader_role_arn
      SPOT_ENABLED                   = var.spot_enabled ? "true" : "false"
      LLM_ENABLED                    = var.llm.enabled ? "true" : "false"
      LLM_REGION                     = var.llm.region
      LLM_MODEL_ID                   = var.llm.model_id
      LLM_MAX_REQUESTS               = tostring(var.llm.max_requests)
      LLM_MAX_TOKENS                 = tostring(var.llm.max_tokens)
      LLM_MAX_CONTEXT_LENGTH         = tostring(var.llm.max_context_length)
      EPISODES_LOG_GROUP             = local.episodes_log_group
      EPISODES_LOG_STREAM            = local.episodes_log_stream
      CHANGES_LOG_STREAM             = local.changes_log_stream
      SPOT_INTERRUPTIONS_LOG_GROUP   = local.spot_interruptions_log_group
      SITEUP_METRIC_NAMESPACE        = "GrampsWeb"
      GRAMPS_WEB_VERSION             = var.gramps_web_version
      MONTHLY_BUDGET_USD             = tostring(var.monthly_budget_usd)
      COST_ENABLED                   = var.cost_enabled ? "true" : "false"
      HOST_METRICS_ENABLED           = var.host_metrics_enabled ? "true" : "false"
      VOLUME_METRICS_ENABLED         = var.volume_metrics_enabled ? "true" : "false"
      PUBLIC_RELIABILITY             = var.public_reliability ? "true" : "false"
    }
  }

  tags = {
    Name = "gramps-web-status"
  }
}

resource "aws_lambda_function_url" "status" {
  function_name      = aws_lambda_function.status.function_name
  authorization_type = "AWS_IAM"
}

resource "aws_cloudwatch_log_group" "status_lambda" {
  name              = "/aws/lambda/gramps-web-status"
  retention_in_days = 30

  tags = {
    Name = "gramps-web-status-lambda"
  }
}
