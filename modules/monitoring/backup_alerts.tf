# Routes AWS Backup job failures to the same alerts topic the availability
# Lambda uses. ABORTED is deliberately excluded from the state filter -- it
# means an operator stopped the job, and that operator already knows.
resource "aws_cloudwatch_event_rule" "backup_failure" {
  count       = var.backup_enabled ? 1 : 0
  name        = "gramps-web-backup-failure"
  description = "Route failed/expired AWS Backup and copy jobs to the alerts topic."

  event_pattern = jsonencode({
    source        = ["aws.backup"]
    "detail-type" = ["Backup Job State Change", "Copy Job State Change"]
    detail        = { state = ["FAILED", "EXPIRED"] }
  })

  tags = {
    Name = "gramps-web-backup-failure"
  }
}

resource "aws_cloudwatch_event_target" "backup_failure" {
  count     = var.backup_enabled ? 1 : 0
  rule      = aws_cloudwatch_event_rule.backup_failure[0].name
  target_id = "alerts-sns"
  arn       = module.availability.sns_topic_arn

  # Flatten the event into a one-line human summary instead of mailing raw
  # EventBridge JSON.
  input_transformer {
    input_paths = {
      detail_type   = "$.detail-type"
      resource_arn  = "$.detail.resourceArn"
      resource_type = "$.detail.resourceType"
      state         = "$.detail.state"
      status        = "$.detail.statusMessage"
    }
    input_template = "\"<detail_type>: <resource_arn> (<resource_type>) is <state>. <status>.\""
  }
}
