output "ebs_volume_id" {
  description = "EBS data volume ID. user-data attaches it by ID at boot; azmove.sh reads it."
  value       = aws_ebs_volume.this.id
}

output "ebs_volume_arn" {
  description = "EBS data volume ARN. Used in instance IAM policy to scope AttachVolume."
  value       = aws_ebs_volume.this.arn
}

output "media_bucket_name" {
  description = "S3 media bucket name."
  value       = aws_s3_bucket.media.id
}

output "media_bucket_arn" {
  description = "S3 media bucket ARN. Used in instance IAM policy."
  value       = aws_s3_bucket.media.arn
}

output "backup_vault_name" {
  description = "Local AWS Backup vault the daily plan writes to. Null when backup.mode = disabled. scripts/backup.sh reads it to take an on-demand recovery point and to report status."
  value       = one(aws_backup_vault.this[*].name)
}

output "backup_copy_vault_arn" {
  description = "Vault each recovery point is copied to: this account's replica vault in backup_region (cross_region) or the backup account's vault (cross_account, ARN constructed from backup.account_id + backup_region + backup.dest_vault_name). Null when backups stay local or are disabled."
  value       = local.backup_copy_vault_arn
}

output "backup_resource_count" {
  description = "Number of resources the AWS Backup selection covers (the EBS data volume and the S3 media bucket). Reported on the backups panel so the recovery-point counts there are visible arithmetic (resource_count x retention_days) rather than numbers to take on faith."
  value       = length(local.backup_resources)
}

output "backup_remote_retention_days" {
  description = "Off-site copy retention actually applied by the plan -- var.backup.remote_retention_days resolved against the '0 means same as local' fallback (see the local's comment above). The status module needs this resolved value, not the raw variable, or the panel prints a retention that doesn't match what copy_action.lifecycle.delete_after sets."
  value       = local.backup_remote_retention_days
}

output "ebs_kms_key_arn" {
  description = "CMK ARN encrypting the data volume; null unless backup.mode = cross_account, which is the only mode that needs one (aws/ebs cannot be shared cross-account). azmove.sh passes it to `rekey` to re-encrypt a volume that predates the key; nothing else consumes it."
  value       = one(aws_kms_key.data[*].arn)
}
