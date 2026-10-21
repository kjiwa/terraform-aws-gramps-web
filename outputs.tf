output "eip_public_ip" {
  description = "EIP public IP. The CloudFront origin address."
  value       = module.compute.eip_public_ip
}

output "asg_name" {
  description = "Auto Scaling Group name. Read by scripts/azmove.sh."
  value       = module.compute.asg_name
}

output "ebs_volume_id" {
  description = "EBS data volume ID. Read by scripts/azmove.sh and scripts/backup.sh snapshot."
  value       = module.storage.ebs_volume_id
}

output "ebs_volume_arn" {
  description = "EBS data volume ARN. Read by scripts/backup.sh run, which passes it to `aws backup start-backup-job --resource-arn`."
  value       = module.storage.ebs_volume_arn
}

output "media_bucket_name" {
  description = "S3 media bucket name."
  value       = module.storage.media_bucket_name
}

output "media_bucket_arn" {
  description = "S3 media bucket ARN. Read by scripts/backup.sh run, which passes it to `aws backup start-backup-job --resource-arn`."
  value       = module.storage.media_bucket_arn
}

output "backup_vault_name" {
  description = "Local AWS Backup vault the daily plan writes to; null when backup.mode = disabled. Read by scripts/backup.sh (run and status)."
  value       = module.storage.backup_vault_name
}

output "backup_copy_vault_arn" {
  description = "Vault each recovery point is copied to (cross_region: this account, backup region; cross_account: the backup account). Null when backups stay local or are disabled. Read by scripts/backup.sh run."
  value       = module.storage.backup_copy_vault_arn
}

output "ebs_kms_key_arn" {
  description = "CMK ARN encrypting the data volume; null unless backup.mode = cross_account (the only mode that needs one). Read by scripts/azmove.sh rekey."
  value       = module.storage.ebs_kms_key_arn
}

output "primary_distribution_id" {
  description = "CloudFront distribution ID for the primary site (manual invalidations)."
  value       = module.edge.primary_distribution_id
}

output "codeconnections_arn" {
  description = "Shared GitHub CodeConnections ARN. Approve once (PENDING -> AVAILABLE) before the first build or pipeline run."
  value       = aws_codeconnections_connection.github.arn
}

output "gramps_pipeline_name" {
  description = "App CodePipeline name. Triggered by scripts/deploy.sh gramps."
  value       = module.app_pipeline.pipeline_name
}

output "ecr_repository_url" {
  description = "ECR repository the app image is pushed to and pulled from."
  value       = module.compute.ecr_repository_url
}

output "status_url" {
  description = "Authenticated operational status page URL (https://<primary_domain>/_status). Requires signing in to Gramps Web at a role >= status.min_role. Null when status.enabled is false."
  value       = var.status.enabled ? "https://${var.primary_domain}/_status" : null
}

output "ami_build_project" {
  description = "AMI CodeBuild project name. Trigger with: aws codebuild start-build --project-name <this>."
  value       = module.ami_build.project_name
}

output "primary_distribution_arn" {
  description = "CloudFront distribution ARN for the primary site. Scope an additional_origins S3 bucket policy to it."
  value       = module.edge.primary_distribution_arn
}
