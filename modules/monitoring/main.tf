# Recorder (canary, alerts topic, episodes and Spot logs, change log) lives in
# the status-page core; the alarms and dashboard in this module are
# Gramps Web specific.
module "availability" {
  source = "git::https://github.com/kjiwa/terraform-aws-status-page.git//modules/availability?ref=v0.1.1"

  name_prefix      = "gramps-web"
  metric_namespace = "GrampsWeb"
  primary_domain   = var.primary_domain
  asg_name         = var.asg_name
  alert_email      = var.alert_email
  active           = var.active

  codedeploy = {
    app_name              = var.codedeploy_app_name
    deployment_group_name = var.codedeploy_deployment_group_name
    deliberate_creators   = var.deliberate_deployment_creators
  }

  last_rightsize_param = {
    name = var.last_rightsize_param_name
    arn  = var.last_rightsize_param_arn
  }
  last_health_watchdog_param = {
    name = var.last_health_watchdog_param_name
    arn  = var.last_health_watchdog_param_arn
  }
  last_backup_snapshot_param = {
    name = var.last_backup_snapshot_param_name
    arn  = var.last_backup_snapshot_param_arn
  }

  alarm_publishers = ["gramps-web-disk-used"]
}
