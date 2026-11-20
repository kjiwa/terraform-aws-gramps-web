# The age alarm needs a build to publish; a failing build publishes nothing, so
# the failed-builds alarm covers that.

# AmiAgeDays is published by each build (scripts/adopt-amis.sh) with the age of
# the oldest running AMI, before any refresh it starts. The threshold is twice
# max_age_days: builds are weekly, so an age over max_age_days is the normal
# moment to refresh, and twice that means the builds are not adopting.
resource "aws_cloudwatch_metric_alarm" "age" {
  alarm_name          = "${local.name}-age"
  alarm_description   = "A running instance of ${var.asg_name} had an AMI over ${var.max_age_days * 2} days old at the last build: builds are failing, or adoption is held (a pinned template version, a refresh in progress, an alarm in ALARM)."
  namespace           = "GrampsWeb"
  metric_name         = "AmiAgeDays"
  dimensions          = { AutoScalingGroupName = var.asg_name }
  statistic           = "Maximum"
  period              = 86400
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.max_age_days * 2
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "failed_builds" {
  alarm_name          = "${local.name}-failed"
  alarm_description   = "The ${local.name} build failed: the smoke check, Packer or the adoption step."
  namespace           = "AWS/CodeBuild"
  metric_name         = "FailedBuilds"
  dimensions          = { ProjectName = aws_codebuild_project.ami.name }
  statistic           = "Sum"
  period              = 86400
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
}
