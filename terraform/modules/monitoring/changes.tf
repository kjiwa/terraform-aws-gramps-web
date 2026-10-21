# Change log: every finished deployment and instance refresh reaches the
# availability Lambda, which appends it to the `changes` stream (see
# handle_deployment() and handle_instance_refresh() there). Only terminal
# states are routed; deployments the ASG creates per launched instance are
# recorded too, and the status page decides what to show.

resource "aws_cloudwatch_event_rule" "deployment_change" {
  name        = "gramps-web-deployment-change"
  description = "Finished CodeDeploy deployments of the app (change log)."

  event_pattern = jsonencode({
    source        = ["aws.codedeploy"]
    "detail-type" = ["CodeDeploy Deployment State-change Notification"]
    detail = {
      application     = [var.codedeploy_app_name]
      deploymentGroup = [var.codedeploy_deployment_group_name]
      state           = ["SUCCESS", "FAILURE", "STOP"]
    }
  })

  tags = {
    Name = "gramps-web-deployment-change"
  }
}

resource "aws_cloudwatch_event_target" "deployment_change" {
  rule      = aws_cloudwatch_event_rule.deployment_change.name
  target_id = "availability-lambda"
  arn       = aws_lambda_function.availability.arn
}

resource "aws_lambda_permission" "deployment_change" {
  statement_id  = "AllowDeploymentChangeRule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.availability.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.deployment_change.arn
}

resource "aws_cloudwatch_event_rule" "instance_refresh_change" {
  name        = "gramps-web-instance-refresh-change"
  description = "Finished instance refreshes of the ASG (change log)."

  event_pattern = jsonencode({
    source = ["aws.autoscaling"]
    "detail-type" = [
      "EC2 Auto Scaling Instance Refresh Succeeded",
      "EC2 Auto Scaling Instance Refresh Failed",
      "EC2 Auto Scaling Instance Refresh Cancelled",
      "EC2 Auto Scaling Instance Refresh Rollback Succeeded",
      "EC2 Auto Scaling Instance Refresh Rollback Failed",
    ]
    detail = {
      AutoScalingGroupName = [var.asg_name]
    }
  })

  tags = {
    Name = "gramps-web-instance-refresh-change"
  }
}

resource "aws_cloudwatch_event_target" "instance_refresh_change" {
  rule      = aws_cloudwatch_event_rule.instance_refresh_change.name
  target_id = "availability-lambda"
  arn       = aws_lambda_function.availability.arn
}

resource "aws_lambda_permission" "instance_refresh_change" {
  statement_id  = "AllowInstanceRefreshChangeRule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.availability.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.instance_refresh_change.arn
}
