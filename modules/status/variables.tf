variable "primary_domain" {
  description = "Apex domain serving the site. The Lambda calls https://<primary_domain>/api/users/-/ to resolve the caller's Gramps Web role; the page is unusable while that origin is down, by design (see lambda/status.py)."
  type        = string
}

variable "min_role" {
  description = "Lowest Gramps Web role (guest, member, contributor, editor, owner, admin) allowed to view /_status/data, or nobody to keep the page deployed but locked to everyone. Compared against the role int GET /api/users/-/ returns for the caller's token; see ROLES in lambda/status.py."
  type        = string
  validation {
    condition     = contains(["guest", "member", "contributor", "editor", "owner", "admin", "nobody"], var.min_role)
    error_message = "min_role must be one of: guest, member, contributor, editor, owner, admin, nobody."
  }
}

variable "asg_name" {
  description = "Auto Scaling Group name. Looked up to find the currently running instance for the host and image panels."
  type        = string
}

variable "codedeploy_app_name" {
  description = "CodeDeploy application name. Read for the deployment panel."
  type        = string
}

variable "codedeploy_deployment_group_name" {
  description = "CodeDeploy deployment group name. Read for the deployment panel and used to scope the ListDeployments/BatchGetDeployments IAM grant."
  type        = string
}

variable "deliberate_deployment_creators" {
  description = "CodeDeploy creator values that count as planned maintenance in the uptime exclusion (modules/compute)."
  type        = list(string)
}

variable "codepipeline_name" {
  description = "CodePipeline name. Read for the deployment panel, to join each CodeDeploy deployment to the commit that triggered it (see ListActionExecutions in lambda/status.py)."
  type        = string
}

variable "source_repo" {
  description = "GitHub owner/repo id (not a URL) the pipeline's Source stage pulls from. Reported alongside each deployment's commit SHA so the frontend can link to it."
  type        = string
}

variable "ecr_repository_name" {
  description = "ECR repository name (not URL). Passed to ecr:DescribeImages to report the most recently pushed image."
  type        = string
}

variable "ecr_repository_arn" {
  description = "ECR repository ARN. Scopes the ecr:DescribeImages IAM grant."
  type        = string
}

variable "ebs_volume_id" {
  description = "EBS data volume ID. Read for the storage panel (size, type, IOPS, encryption, attachment state)."
  type        = string
}

variable "media_bucket_name" {
  description = "S3 media bucket name. Read for the storage panel's BucketSizeBytes/NumberOfObjects CloudWatch metrics."
  type        = string
}

variable "backup_vault_name" {
  description = "Local AWS Backup vault name. Empty string disables the backups panel (backup.mode = disabled reports no vault)."
  type        = string
  default     = ""
}

variable "backup_mode" {
  description = "Off-site backup destination mode, reported as-is on the backups panel. See the backup variable in terraform/roots/stack/variables.tf for the full semantics (local/cross_region/cross_account/disabled); this module does not re-derive or re-explain them."
  type        = string
  default     = ""
}

variable "backup_schedule" {
  description = "AWS Backup plan schedule (a cron(...) or rate(...) expression), reported as-is on the backups panel."
  type        = string
  default     = ""
}

variable "backup_retention_days" {
  description = "Local recovery point retention in days, reported on the backups panel."
  type        = number
  default     = 0
}

variable "backup_resource_count" {
  description = "Number of resources the AWS Backup selection covers, reported on the backups panel."
  type        = number
  default     = 0
}

variable "backup_remote_retention_days" {
  description = "Off-site copy retention in days, reported on the backups panel."
  type        = number
  default     = 0
}

variable "backup_region" {
  description = "Off-site backup copy destination region, reported on the backups panel. Not necessarily this Lambda's own region, and independent of backup_copy_vault_arn's region so the panel doesn't have to parse it back out of that ARN."
  type        = string
  default     = ""
}

variable "backup_copy_vault_arn" {
  description = "Off-site backup copy destination vault ARN. The backups panel parses it for the destination account ID and vault name only (region comes from backup_region) and never calls DescribeBackupVault on it -- under backup.mode = cross_account it lives in another account this Lambda's role has no grant into. Empty when backups stay local or are disabled."
  type        = string
  default     = ""
}

variable "backup_dest_reader_role_arn" {
  description = "ARN of the backup account's gramps-web-vault-reader role, granting DescribeBackupVault on the destination vault only. Empty unless backup.mode = cross_account, in which case the backups panel assumes this role to read the destination vault's lock state live; for cross_region the destination vault is in this same account and is read directly instead (see the DescribeBackupVault statement in iam.tf)."
  type        = string
  default     = ""
}

variable "spot_enabled" {
  description = "Whether the fleet runs on Spot. Reported as spot_enabled in both status payloads so the Spot reclaims panel also shows for a Spot deployment that has had no reclaims yet."
  type        = bool
  default     = false
}

variable "llm" {
  description = "AI chat assistant runtime config, resolved (region already picks the override vs primary_region). See the llm variable in terraform/roots/stack/variables.tf for the full field-by-field rationale. enabled: if true, the assistant panel reports 30-day Bedrock InputTokenCount+OutputTokenCount from region; if false, the panel and its IAM grant do not exist. model_id/max_requests/max_tokens/max_context_length are shown as config rows on the Assistant panel; model_id is reported from config rather than discovered from CloudWatch (see the comment on assistant() in lambda/status.py for why a per-model breakdown isn't available)."
  type = object({
    enabled            = bool
    model_id           = string
    region             = string
    max_requests       = number
    max_tokens         = number
    max_context_length = number
  })
  default = {
    enabled            = false
    model_id           = ""
    region             = ""
    max_requests       = 0
    max_tokens         = 0
    max_context_length = 0
  }
}

variable "gramps_web_version" {
  description = "Upstream grampsweb image tag the app pipeline builds from. Shown as-is on the page; purely informational."
  type        = string
}

variable "monthly_budget_usd" {
  description = "FinOps monthly cost budget in USD, shown alongside the cost panel's month-to-date figure for context. Purely informational; does not affect the budget itself."
  type        = number
}

variable "cost_enabled" {
  description = "If true, the cost panel queries Cost Explorer (GetCostAndUsage, us-east-1) for month-to-date spend by service, cached in the Lambda's execution environment for 1 hour to avoid repeatedly incurring the $0.01/request Cost Explorer charge. If false, the panel and its IAM grant do not exist. Defaults off because every request is billed."
  type        = bool
  default     = false
}

variable "host_metrics_enabled" {
  description = "If true, the host_metrics panel reads the disk/memory custom metrics the instance itself publishes every 5 minutes (build/ami/health-watchdog.sh), which costs a few cents a month in custom-metric charges. If false, the panel is absent and the instance publishes nothing (see status_host_metrics in modules/compute)."
  type        = bool
  default     = false
}

variable "volume_metrics_enabled" {
  description = "If true, the Storage panel's disk reading comes from exact used/total byte metrics for both the data volume and root instead of a single integer percent for the data volume. Requires host_metrics_enabled (enforced by the root variable's validation, not here). See status_volume_metrics in modules/compute for the publisher side."
  type        = bool
  default     = false
}

variable "public_reliability" {
  description = "If true, GET /_status/public serves the reliability and incidents panels, redacted and unauthenticated, from a warm cache (PUBLIC_CACHE_TTL_S in lambda/status.py). If false, that route 404s regardless of what CloudFront routes to it. See public_reliability in the status variable, terraform/roots/stack/variables.tf, for the full feature description."
  type        = bool
  default     = false
}
