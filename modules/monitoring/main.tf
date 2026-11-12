# Recorder (canary, alerts topic, episodes and Spot logs, change log) and the
# backup alert, disk alarm and dashboard live in the status-page modules.
module "availability" {
  source = "git::https://github.com/kjiwa/terraform-aws-status-page.git//modules/availability?ref=v0.7.0"

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

  alarm_publishers = module.host_alarms.alarm_names
}

module "host_alarms" {
  source = "git::https://github.com/kjiwa/terraform-aws-status-page.git//modules/host-alarms?ref=v0.7.0"

  name_prefix      = "gramps-web"
  metric_namespace = "GrampsWeb"
  alarm_topic_arn  = module.availability.sns_topic_arn
  backup_enabled   = var.backup_enabled

  episodes_log_group_name           = module.availability.episodes_log_group_name
  spot_interruptions_log_group_name = module.availability.spot_interruptions_log_group_name

  host_metrics_enabled   = var.host_metrics_enabled
  volume_metrics_enabled = var.volume_metrics_enabled
}
