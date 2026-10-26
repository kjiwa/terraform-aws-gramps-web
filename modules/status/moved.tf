# Resources that moved into the core status module.

moved {
  from = aws_lambda_function.status
  to   = module.core.aws_lambda_function.status
}

moved {
  from = aws_lambda_function_url.status
  to   = module.core.aws_lambda_function_url.status
}

moved {
  from = aws_cloudwatch_log_group.status_lambda
  to   = module.core.aws_cloudwatch_log_group.status_lambda
}

moved {
  from = aws_iam_role.status
  to   = module.core.aws_iam_role.status
}

moved {
  from = aws_iam_role_policy.status
  to   = module.core.aws_iam_role_policy.status
}
