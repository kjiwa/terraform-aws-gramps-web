# Starts the build weekly and when the app image for gramps_web_version is
# pushed to ECR (the deploy pushes it, so a Gramps Web bump is baked once it is
# deployed). Both are off while ami_ids pins the AMIs.
data "aws_iam_policy_document" "events_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events" {
  count = var.auto_build ? 1 : 0

  name               = "${local.name}-events"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json

  tags = {
    Name = "${local.name}-events"
  }
}

data "aws_iam_policy_document" "events" {
  statement {
    effect    = "Allow"
    actions   = ["codebuild:StartBuild"]
    resources = [aws_codebuild_project.ami.arn]
  }
}

resource "aws_iam_role_policy" "events" {
  count = var.auto_build ? 1 : 0

  name   = "${local.name}-events"
  role   = aws_iam_role.events[0].id
  policy = data.aws_iam_policy_document.events.json
}

resource "aws_cloudwatch_event_rule" "weekly" {
  count = var.auto_build ? 1 : 0

  name                = "${local.name}-weekly"
  description         = "Weekly base AMI build."
  schedule_expression = "cron(0 6 ? * SUN *)"
}

resource "aws_cloudwatch_event_target" "weekly" {
  count = var.auto_build ? 1 : 0

  rule     = aws_cloudwatch_event_rule.weekly[0].name
  arn      = aws_codebuild_project.ami.arn
  role_arn = aws_iam_role.events[0].arn
}

resource "aws_cloudwatch_event_rule" "image_pushed" {
  count = var.auto_build ? 1 : 0

  name        = "${local.name}-image-pushed"
  description = "Base AMI build when the app image for gramps_web_version is pushed."
  event_pattern = jsonencode({
    source        = ["aws.ecr"]
    "detail-type" = ["ECR Image Action"]
    detail = {
      "action-type"     = ["PUSH"]
      result            = ["SUCCESS"]
      "repository-name" = [var.ecr_repository_name]
      "image-tag"       = [var.gramps_web_version]
    }
  })
}

resource "aws_cloudwatch_event_target" "image_pushed" {
  count = var.auto_build ? 1 : 0

  rule     = aws_cloudwatch_event_rule.image_pushed[0].name
  arn      = aws_codebuild_project.ami.arn
  role_arn = aws_iam_role.events[0].arn
}
