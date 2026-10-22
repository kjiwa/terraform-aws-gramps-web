output "eip_public_ip" {
  description = "EIP public IP address. Used as the CloudFront origin."
  value       = aws_eip.origin.public_ip
}

output "asg_name" {
  description = "Auto Scaling Group name."
  value       = aws_autoscaling_group.this.name
}

output "instance_role_name" {
  description = "IAM role name attached to EC2 instances. The app-pipeline module attaches its artifact-bucket read grant to it."
  value       = aws_iam_role.instance.name
}

output "codedeploy_app_name" {
  description = "CodeDeploy application name."
  value       = aws_codedeploy_app.this.name
}

output "codedeploy_deployment_group_name" {
  description = "CodeDeploy deployment group name."
  value       = aws_codedeploy_deployment_group.this.deployment_group_name
}

output "ecr_repository_url" {
  description = "ECR repository URL for the Gramps Web image. The app pipeline pushes here; instances pull from here."
  value       = aws_ecr_repository.gramps.repository_url
}

output "ecr_repository_arn" {
  description = "ECR repository ARN. Scopes the app pipeline's push permissions."
  value       = aws_ecr_repository.gramps.arn
}

output "last_rightsize_param_name" {
  description = "SSM parameter name the rightsize watchdog writes its cause-attribution marker to. Read by the monitoring module's availability Lambda."
  value       = aws_ssm_parameter.last_rightsize.name
}

output "last_rightsize_param_arn" {
  description = "ARN of the rightsize watchdog's marker parameter. Scopes the monitoring module's read grant."
  value       = aws_ssm_parameter.last_rightsize.arn
}

output "last_health_watchdog_param_name" {
  description = "SSM parameter name the health watchdog writes its cause-attribution marker to. Read by the monitoring module's availability Lambda."
  value       = aws_ssm_parameter.last_health_watchdog.name
}

output "last_health_watchdog_param_arn" {
  description = "ARN of the health watchdog's marker parameter. Scopes the monitoring module's read grant."
  value       = aws_ssm_parameter.last_health_watchdog.arn
}

output "last_backup_snapshot_param_name" {
  description = "SSM parameter name scripts/backup.sh snapshot writes its cause-attribution marker to. Read by the monitoring module's availability Lambda."
  value       = aws_ssm_parameter.last_backup_snapshot.name
}

output "last_backup_snapshot_param_arn" {
  description = "ARN of the backup snapshot marker parameter. Scopes the monitoring module's read grant."
  value       = aws_ssm_parameter.last_backup_snapshot.arn
}

output "deliberate_deployment_creators" {
  description = "CodeDeploy `creator` values that mean a person or a rollback started a deployment, as opposed to the ASG deploying to an instance it launched. The one definition both Lambdas read."
  value       = ["user", "codeDeployRollback"]
}
