# Teardown

`terraform destroy` stops by design: the data volume, the media bucket, the backup vault, and the vault key carry `prevent_destroy`. Tear down only a deployment whose data you no longer want; the backups go with it.

1. Take a final backup if you want one (`scripts/backup.sh --root DIR run`), and download what you need.
2. Remove the four `prevent_destroy` guards in your checkout of the module: the data volume and media bucket in `modules/storage/main.tf`, the vault and its key in `modules/storage/backup.tf`.
3. Delete every recovery point in the vault (`aws backup list-recovery-points-by-backup-vault`, then `delete-recovery-point`). A vault with recovery points cannot be deleted.
4. Empty the versioned buckets, including old versions and delete markers: media, pipeline artifacts, build cache, and error pages. Empty the ECR repository.
5. Run `terraform destroy` in the root. Re-run it if it times out waiting on a CloudFront distribution or certificate.
6. Deregister the base AMIs and delete their snapshots (`scripts/clean-amis.sh`, or by hand); Terraform does not own them.

The keel audit trail bucket is Object-Locked in governance mode for `log_retention_days` (default 365), so it cannot be emptied until that period passes. For a throwaway deployment set `log_retention_days` to 1 on the `audit` module before the first apply (`audit_log_retention_days` in `examples/minimal`). To destroy a deployment created with the default, delete the objects with `--bypass-governance-retention` as an identity allowed to, or run `terraform state rm module.audit.aws_s3_bucket.trail` and leave the bucket behind.
