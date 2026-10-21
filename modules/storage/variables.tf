variable "az" {
  description = "Availability zone for the EBS volume. Must match the instance AZ."
  type        = string
}

variable "data_volume_gib" {
  description = "Size of the EBS data volume in GiB (gp3). Raising it is an in-place ModifyVolume; lowering it is not (scripts/azmove.sh shrink)."
  type        = number
  default     = 5
}

variable "media_bucket_name" {
  description = "S3 bucket name for Gramps media. Globally unique. Empty string derives gramps-web-media-<account-id>."
  type        = string
  default     = ""
}

variable "backup" {
  description = "Off-site backup destination for the irreplaceable data (the EBS data volume and the S3 media bucket), via AWS Backup. See the root stack's var.backup for the full semantics; this module consumes the resolved object. mode: local (daily recovery points in this account/region only), cross_region (also copy them to a vault this module creates in backup_region), cross_account (also copy them to a vault another org account owns), disabled (no scheduled backups). schedule is the plan's cron/rate expression -- see the root variable."
  type = object({
    mode                  = string
    region                = string
    account_id            = string
    retention_days        = number
    remote_retention_days = number
    dest_vault_name       = string
    schedule              = string
  })
}

variable "backup_region" {
  description = "Resolved destination region for off-site copies (string). Equals the primary region when backups are local or disabled, where the replica resources have count 0. Under cross_account this is the region half of the constructed destination vault ARN, so it must match the backup account's own region variable."
  type        = string
}

variable "data_volume_snapshot_id" {
  description = "EC2 snapshot ID to create the data volume from. First apply only -- snapshot_id is ForceNew and the volume carries prevent_destroy, so setting this on a live deployment plans a replace that errors instead of adopting it; that is the guard working, not a bug. For rebuilding a fresh environment from a disaster-recovery snapshot (scripts/restore.sh offsite, then snapshot the result -- see docs/restore.md). Putting a restored volume into a running environment is docs/az-move.md (adopt), not this."
  type        = string
  default     = null
}
