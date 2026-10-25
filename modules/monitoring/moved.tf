# Resources that moved into the recorder module. The deployment_change trio
# is count-indexed there.

moved {
  from = aws_sns_topic.alerts
  to   = module.availability.aws_sns_topic.alerts
}

moved {
  from = aws_sns_topic_policy.alerts
  to   = module.availability.aws_sns_topic_policy.alerts
}

moved {
  from = aws_sns_topic_subscription.alerts_email
  to   = module.availability.aws_sns_topic_subscription.alerts_email
}

moved {
  from = aws_cloudwatch_metric_alarm.site_down
  to   = module.availability.aws_cloudwatch_metric_alarm.site_down
}

moved {
  from = aws_cloudwatch_event_rule.alarm_state
  to   = module.availability.aws_cloudwatch_event_rule.alarm_state
}

moved {
  from = aws_cloudwatch_event_target.alarm_state
  to   = module.availability.aws_cloudwatch_event_target.alarm_state
}

moved {
  from = aws_lambda_permission.alarm_state
  to   = module.availability.aws_lambda_permission.alarm_state
}

moved {
  from = aws_cloudwatch_event_rule.deployment_change
  to   = module.availability.aws_cloudwatch_event_rule.deployment_change[0]
}

moved {
  from = aws_cloudwatch_event_target.deployment_change
  to   = module.availability.aws_cloudwatch_event_target.deployment_change[0]
}

moved {
  from = aws_lambda_permission.deployment_change
  to   = module.availability.aws_lambda_permission.deployment_change[0]
}

moved {
  from = aws_cloudwatch_event_rule.instance_refresh_change
  to   = module.availability.aws_cloudwatch_event_rule.instance_refresh_change
}

moved {
  from = aws_cloudwatch_event_target.instance_refresh_change
  to   = module.availability.aws_cloudwatch_event_target.instance_refresh_change
}

moved {
  from = aws_lambda_permission.instance_refresh_change
  to   = module.availability.aws_lambda_permission.instance_refresh_change
}

moved {
  from = aws_lambda_function.availability
  to   = module.availability.aws_lambda_function.availability
}

moved {
  from = aws_cloudwatch_log_group.lambda
  to   = module.availability.aws_cloudwatch_log_group.lambda
}

moved {
  from = aws_ssm_parameter.state
  to   = module.availability.aws_ssm_parameter.state
}

moved {
  from = aws_cloudwatch_log_group.episodes
  to   = module.availability.aws_cloudwatch_log_group.episodes
}

moved {
  from = aws_cloudwatch_log_stream.episodes
  to   = module.availability.aws_cloudwatch_log_stream.episodes
}

moved {
  from = aws_cloudwatch_log_stream.changes
  to   = module.availability.aws_cloudwatch_log_stream.changes
}

moved {
  from = aws_cloudwatch_event_rule.canary
  to   = module.availability.aws_cloudwatch_event_rule.canary
}

moved {
  from = aws_cloudwatch_event_target.canary
  to   = module.availability.aws_cloudwatch_event_target.canary
}

moved {
  from = aws_lambda_permission.canary
  to   = module.availability.aws_lambda_permission.canary
}

moved {
  from = aws_iam_role.availability
  to   = module.availability.aws_iam_role.availability
}

moved {
  from = aws_iam_role_policy.availability
  to   = module.availability.aws_iam_role_policy.availability
}

moved {
  from = aws_cloudwatch_event_rule.spot_interruption
  to   = module.availability.aws_cloudwatch_event_rule.spot_interruption
}

moved {
  from = aws_cloudwatch_event_target.spot_lambda
  to   = module.availability.aws_cloudwatch_event_target.spot_lambda
}

moved {
  from = aws_lambda_permission.spot_interruption
  to   = module.availability.aws_lambda_permission.spot_interruption
}

moved {
  from = aws_cloudwatch_log_group.spot_interruptions
  to   = module.availability.aws_cloudwatch_log_group.spot_interruptions
}

moved {
  from = aws_cloudwatch_log_resource_policy.spot_log_delivery
  to   = module.availability.aws_cloudwatch_log_resource_policy.spot_log_delivery
}

moved {
  from = aws_cloudwatch_event_target.spot_log
  to   = module.availability.aws_cloudwatch_event_target.spot_log
}
