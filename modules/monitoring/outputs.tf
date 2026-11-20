output "episodes_log_group_name" {
  description = "Log group holding the outage episodes and the change log. Read by modules/status."
  value       = module.availability.episodes_log_group_name
}

output "spot_interruptions_log_group_name" {
  description = "Log group holding raw Spot interruption warnings. Read by modules/status."
  value       = module.availability.spot_interruptions_log_group_name
}

output "alert_topic_arn" {
  description = "ARN of the alerts SNS topic. The AMI build's alarms notify it."
  value       = module.availability.sns_topic_arn
}
