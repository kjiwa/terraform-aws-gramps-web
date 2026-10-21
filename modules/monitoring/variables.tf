variable "active" {
  description = "If false the environment is asleep: the canary schedule and the alarm-notification rule are disabled so a deliberately-empty ASG does not page anyone. Re-enabling sends one RECOVERED notice once the site is back."
  type        = bool
}

variable "backup_enabled" {
  description = "Whether AWS Backup is running in this environment (var.backup.mode != disabled at the root). Gates the backup-failure alert rule."
  type        = bool
}

variable "primary_domain" {
  description = "Apex domain serving the site. The canary probes https://<primary_domain>/."
  type        = string
}

variable "asg_name" {
  description = "Auto Scaling Group name. Used to look up the replacement instance after an outage."
  type        = string
}

variable "alert_email" {
  description = "Email address that receives DOWN/RECOVERED notices. Confirm the SNS subscription email after the first apply."
  type        = string
}

variable "codedeploy_app_name" {
  description = "CodeDeploy application name. Queried for cause attribution: an outage starting near a deployment's createTime is attributed to it."
  type        = string
}

variable "codedeploy_deployment_group_name" {
  description = "CodeDeploy deployment group name. Paired with codedeploy_app_name for the deploy cause-attribution query."
  type        = string
}

variable "last_rightsize_param_name" {
  description = "SSM parameter name the rightsize watchdog writes its cause-attribution marker to (modules/compute). Read by the availability Lambda."
  type        = string
}

variable "last_rightsize_param_arn" {
  description = "ARN of last_rightsize_param_name. Scopes the availability Lambda's ssm:GetParameter grant."
  type        = string
}

variable "last_health_watchdog_param_name" {
  description = "SSM parameter name the health watchdog writes its cause-attribution marker to (modules/compute). Read by the availability Lambda."
  type        = string
}

variable "last_health_watchdog_param_arn" {
  description = "ARN of last_health_watchdog_param_name. Scopes the availability Lambda's ssm:GetParameter grant."
  type        = string
}

variable "host_metrics_enabled" {
  description = "Whether the instance publishes disk/memory metrics (status.host_metrics at the root). Gates the data-volume disk alarm."
  type        = bool
}

variable "volume_metrics_enabled" {
  description = "Whether the instance publishes the DiskUsedBytes/DiskTotalBytes pair (status.volume_metrics at the root) instead of DiskUsedPercent. Selects the disk alarm's metric source."
  type        = bool
}

variable "last_backup_snapshot_param_name" {
  description = "SSM parameter name scripts/backup.sh snapshot writes its cause-attribution marker to (modules/compute). Read by the availability Lambda."
  type        = string
}

variable "last_backup_snapshot_param_arn" {
  description = "ARN of last_backup_snapshot_param_name. Scopes the availability Lambda's ssm:GetParameter grant."
  type        = string
}

variable "deliberate_deployment_creators" {
  description = "CodeDeploy creator values that count as a deliberate deploy for cause attribution (modules/compute)."
  type        = list(string)
}
