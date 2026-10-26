output "primary_distribution_id" {
  description = "CloudFront distribution ID for the primary site."
  value       = aws_cloudfront_distribution.primary.id
}

output "primary_distribution_arn" {
  description = "CloudFront distribution ARN for the primary site. Scope a bucket policy for an additional_origins S3 origin to it."
  value       = aws_cloudfront_distribution.primary.arn
}

output "errors_bucket_name" {
  description = "S3 bucket holding the static custom error pages. Read by the web-build module's publish policy (build/web/src/error/)."
  value       = aws_s3_bucket.errors.bucket
}

output "errors_bucket_arn" {
  description = "ARN of the error-pages bucket. Read by the web-build module's publish policy."
  value       = aws_s3_bucket.errors.arn
}
