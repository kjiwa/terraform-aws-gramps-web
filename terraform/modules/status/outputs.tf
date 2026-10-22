output "function_name" {
  description = "Lambda function name. Referenced by the edge module's aws_lambda_permission so CloudFront OAC may invoke the Function URL."
  value       = aws_lambda_function.status.function_name
}

output "function_url" {
  description = "Lambda Function URL (https://<id>.lambda-url.<region>.on.aws/). The edge module strips the scheme/trailing slash and uses the bare hostname as the CloudFront origin domain_name."
  value       = aws_lambda_function_url.status.function_url
}
