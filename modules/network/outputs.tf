output "subnet_ids" {
  description = "Public subnet IDs the ASG launches into."
  value       = [aws_subnet.public.id]
}

output "origin_sg_id" {
  description = "Origin security group ID. Allows HTTP from CloudFront origin-facing prefix list."
  value       = aws_security_group.origin.id
}
