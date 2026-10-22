variable "primary_domain" {
  description = "Apex domain the site is served from (string). Point its registrar at the name servers this stack outputs."
  type        = string
}

variable "alert_email" {
  description = "Address for outage, cost, and audit alerts (string)."
  type        = string
}

variable "region" {
  description = "Region the site runs in (string). CloudFront certificates always use us-east-1."
  type        = string
  default     = "us-east-1"
}

variable "repo_url" {
  description = "HTTPS GitHub URL of your fork of the module repository (string); the CodeConnections app installs on it."
  type        = string
  default     = "https://github.com/kjiwa/terraform-aws-gramps-web"
}

variable "source_branch" {
  description = "Release branch of repo_url matching the module ref (string)."
  type        = string
  default     = "main"
}

variable "audit_log_retention_days" {
  description = "Days the audit trail is retained and Object-Locked (number). Lower it for a trial: the locked bucket cannot be emptied, so it blocks teardown until it expires."
  type        = number
  default     = 365
}
