# CodeDeploy owns the Gramps Web version. The deployment group is wired to the
# ASG, so a manual `scripts/deploy.sh` rolls the running instance in place AND any new
# instance (spot replacement / instance refresh) auto-receives the last
# successful revision on launch.

resource "aws_codedeploy_app" "this" {
  name             = "gramps-web"
  compute_platform = "Server"
}

resource "aws_codedeploy_deployment_group" "this" {
  app_name               = aws_codedeploy_app.this.name
  deployment_group_name  = "gramps-web-${var.env}"
  service_role_arn       = aws_iam_role.codedeploy.arn
  autoscaling_groups     = [aws_autoscaling_group.this.name]
  deployment_config_name = "CodeDeployDefault.AllAtOnce"

  deployment_style {
    deployment_type   = "IN_PLACE"
    deployment_option = "WITHOUT_TRAFFIC_CONTROL"
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }
}

# --- CodeDeploy service role -------------------------------------------------

data "aws_iam_policy_document" "codedeploy_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codedeploy" {
  name               = "gramps-web-codedeploy"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_assume.json

  tags = {
    Name = "gramps-web-codedeploy"
  }
}

resource "aws_iam_role_policy_attachment" "codedeploy" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
}

