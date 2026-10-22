resource "aws_ssm_parameter" "smtp_password" {
  name        = "/gramps-web/${var.env}/smtp-password"
  description = "SES SMTP password (ses_smtp_password_v4) for the gramps-web-ses-smtp user. Region-derived; rotate by recreating the access key."
  type        = "SecureString"
  value       = aws_iam_access_key.smtp.ses_smtp_password_v4

  tags = {
    Name = "gramps-web-smtp-password"
  }
}
