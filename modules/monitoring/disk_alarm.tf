# Data volume (a fixed-size EBS holding the database and stored backups) above
# 85% used. Reads what build/ami/health-watchdog.sh publishes when
# host_metrics is on: DiskUsedPercent, or with volume_metrics the
# DiskUsedBytes/DiskTotalBytes pair for Mount=data, which supersedes it.
#
# treat_missing_data = "ignore", like instance_refresh_pathological: the
# publisher is silent while the env sleeps or on an AMI predating it, and
# "notBreaching" would report OK on a dead publisher while "breaching" would
# page on every sleep. Publishes every 5 minutes, so the 15-minute period
# always holds at least two points. With volume_metrics on, the alarm stays
# silent until the running AMI publishes the byte pair (one baked before that
# series existed publishes only the percent), so rebuild the AMI first.
resource "aws_cloudwatch_metric_alarm" "disk_used" {
  count = var.host_metrics_enabled ? 1 : 0

  alarm_name          = "gramps-web-disk-used"
  alarm_description   = "Data volume is above 85% used."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 85
  treat_missing_data  = "ignore"
  alarm_actions       = [module.availability.sns_topic_arn]

  dynamic "metric_query" {
    for_each = var.volume_metrics_enabled ? [1] : []
    content {
      id          = "pct"
      expression  = "100 * used / total"
      label       = "Data volume used (%)"
      return_data = true
    }
  }

  dynamic "metric_query" {
    for_each = var.volume_metrics_enabled ? ["used", "total"] : []
    content {
      id = metric_query.value
      metric {
        namespace   = "GrampsWeb"
        metric_name = metric_query.value == "used" ? "DiskUsedBytes" : "DiskTotalBytes"
        dimensions  = { Mount = "data" }
        stat        = "Maximum"
        period      = 900
      }
    }
  }

  dynamic "metric_query" {
    for_each = var.volume_metrics_enabled ? [] : [1]
    content {
      id          = "pct"
      label       = "Data volume used (%)"
      return_data = true
      metric {
        namespace   = "GrampsWeb"
        metric_name = "DiskUsedPercent"
        stat        = "Maximum"
        period      = 900
      }
    }
  }

  tags = {
    Name = "gramps-web-disk-used"
  }
}
