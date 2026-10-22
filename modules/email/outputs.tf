output "smtp_host" {
  description = "SES SMTP endpoint hostname."
  value       = local.smtp_host
}

output "smtp_username" {
  description = "SMTP username (IAM access key ID for the SES SMTP user)."
  value       = aws_iam_access_key.smtp.id
}

output "smtp_password_ssm_path" {
  description = "SSM SecureString parameter name holding the SMTP password."
  value       = aws_ssm_parameter.smtp_password.name
}

output "from_address" {
  description = "Default From address for outbound mail."
  value       = local.from_address
}

output "smtp_port" {
  description = "SMTP port. Fixed at 587 (SES STARTTLS) -- the only combination this module's SES setup supports."
  value       = 587
}

output "smtp_use_starttls" {
  description = "Whether SMTP uses STARTTLS. Fixed at true, paired with smtp_port = 587."
  value       = true
}
