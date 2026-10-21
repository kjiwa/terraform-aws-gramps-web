resource "aws_iam_user" "smtp" {
  name = "gramps-web-ses-smtp"

  tags = {
    Name = "gramps-web-ses-smtp"
  }
}

# SES SMTP cannot authenticate with the instance role, so a dedicated user
# with a long-lived key is required. Scope to our identity and From address.
data "aws_iam_policy_document" "smtp_send" {
  statement {
    sid       = "SESSend"
    effect    = "Allow"
    actions   = ["ses:SendRawEmail"]
    resources = [aws_sesv2_email_identity.this.arn]

    condition {
      test     = "StringEquals"
      variable = "ses:FromAddress"
      values   = [local.from_address]
    }
  }
}

resource "aws_iam_user_policy" "smtp_send" {
  name   = "ses-send"
  user   = aws_iam_user.smtp.name
  policy = data.aws_iam_policy_document.smtp_send.json
}

resource "aws_iam_access_key" "smtp" {
  user = aws_iam_user.smtp.name
}
