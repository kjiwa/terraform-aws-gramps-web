# Targets modules/monitoring directly with the inputs the root would pass.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/test" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1", name = "us-east-1" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  active                           = true
  primary_domain                   = "example.org"
  asg_name                         = "gramps-web"
  alert_email                      = "ops@example.org"
  backup_enabled                   = true
  host_metrics_enabled             = true
  volume_metrics_enabled           = true
  codedeploy_app_name              = "gramps-web"
  codedeploy_deployment_group_name = "gramps-web"
  last_rightsize_param_name        = "/gramps-web/last-rightsize"
  last_rightsize_param_arn         = "arn:aws:ssm:us-east-1:123456789012:parameter/gramps-web/last-rightsize"
  last_health_watchdog_param_name  = "/gramps-web/last-health-watchdog"
  last_health_watchdog_param_arn   = "arn:aws:ssm:us-east-1:123456789012:parameter/gramps-web/last-health-watchdog"
  last_backup_snapshot_param_name  = "/gramps-web/last-backup-snapshot"
  last_backup_snapshot_param_arn   = "arn:aws:ssm:us-east-1:123456789012:parameter/gramps-web/last-backup-snapshot"
  deliberate_deployment_creators   = ["user"]
}

run "host_alarms_publish_the_data_disk_alarm" {
  command = plan
  module {
    source = "./modules/monitoring"
  }

  assert {
    condition     = tolist(module.host_alarms.alarm_names) == tolist(["gramps-web-disk-used"])
    error_message = "The live disk alarm name must survive the move into host-alarms."
  }
}

run "host_metrics_off_leaves_no_alarm" {
  command = plan
  module {
    source = "./modules/monitoring"
  }
  variables {
    host_metrics_enabled   = false
    volume_metrics_enabled = false
  }

  assert {
    condition     = length(module.host_alarms.alarm_names) == 0
    error_message = "No host metrics, no disk alarm."
  }
}
