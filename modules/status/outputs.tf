output "origins" {
  description = "CloudFront origins for the primary distribution: the shell bucket and the status Lambda (modules/edge status_origins)."
  value       = module.core.origins
}

output "behaviors" {
  description = "CloudFront ordered cache behaviors for the primary distribution (modules/edge status_behaviors)."
  value       = module.core.behaviors
}
