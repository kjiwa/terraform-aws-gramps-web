output "episodes_log_group_name" {
  description = "Log group holding the outage episodes and the change log. Read by modules/status."
  value       = module.availability.episodes_log_group_name
}

output "spot_interruptions_log_group_name" {
  description = "Log group holding raw Spot interruption warnings. Read by modules/status."
  value       = module.availability.spot_interruptions_log_group_name
}
