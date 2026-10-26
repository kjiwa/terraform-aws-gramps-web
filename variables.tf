variable "primary_domain" {
  description = "Canonical apex domain (string). Every other entry in domains, and every www. host, 301s to it. Its Route 53 hosted zone must already exist."
  type        = string
}

variable "alert_email" {
  description = "Address that receives site DOWN/RECOVERED notices and Spot interruption alerts (string). Confirm the SNS subscription email after the first apply."
  type        = string
  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "domains" {
  description = "Apex domains served (list of strings), or null to serve only primary_domain. Each needs an existing public Route 53 hosted zone, such as keel's dns module creates."
  type        = list(string)
  default     = null
  validation {
    condition     = var.domains == null || contains(var.domains, var.primary_domain)
    error_message = "domains must include primary_domain."
  }
  validation {
    condition     = var.domains == null || alltrue([for d in var.domains : d == lower(d)])
    error_message = "Domain names must be lowercase because they flow into S3 bucket names."
  }
  validation {
    condition     = var.domains == null || length(var.domains) == length(distinct(var.domains))
    error_message = "domains must not contain duplicates."
  }
}

variable "env" {
  description = "Environment name (string) that namespaces SSM parameter paths and the CodeDeploy deployment group. Fixed resource names mean one deployment per AWS account."
  type        = string
  default     = "prod"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,19}$", var.env))
    error_message = "env must be 1 to 20 characters of lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "active" {
  description = "Whether the site runs (bool). False sleeps it: zero instances and no canary alarms, all data kept; public IPv4, KMS keys, the hosted zone, ECR, and EBS still bill (about 10 to 15 USD per month); waking takes about five minutes."
  type        = bool
  default     = true
}

variable "az" {
  description = "Availability zone of the instance and data volume (string), or null for the region's first available zone. Changing it on a live deployment replaces the volume (docs/az-move.md)."
  type        = string
  default     = null
}

variable "ami_ids" {
  description = "Base AMI ID per architecture (map with keys arm64 and x86_64), or null to use the newest self-owned AMI tagged Name=gramps-web-base. Null follows the newest AMI, so a new build rolls out on the next apply; pin to hold it. The build cleanup keeps only the newest AMI per architecture plus those referenced by launch template versions or running instances, so rolling back by pinning reaches only an AMI still referenced. The AMIs come from the build project this module creates."
  type        = map(string)
  default     = null
  validation {
    condition     = var.ami_ids == null || sort(keys(var.ami_ids)) == tolist(["arm64", "x86_64"])
    error_message = "ami_ids must be null or have exactly the keys arm64 and x86_64."
  }
  validation {
    condition     = var.ami_ids == null || alltrue([for v in values(var.ami_ids) : can(regex("^ami-[0-9a-f]+$", v))])
    error_message = "ami_ids values must be AMI IDs matching ^ami-[0-9a-f]+$."
  }
}

variable "site_title" {
  description = "Site name shown on error pages (string), or empty to use primary_domain."
  type        = string
  default     = ""
}

variable "data_volume_gib" {
  description = "Size of the gp3 data volume in GiB (number), billed per GiB-month. Raising it is in place; lowering it is not (scripts/azmove.sh shrink)."
  type        = number
  default     = 5
  validation {
    condition     = var.data_volume_gib >= 1 && var.data_volume_gib == floor(var.data_volume_gib)
    error_message = "data_volume_gib must be a whole number of GiB, at least 1."
  }
}

variable "data_volume_snapshot_id" {
  description = "EC2 snapshot ID to create the data volume from (string), or null for an empty volume. First apply only: on a live deployment it plans a refused replace (docs/restore.md)."
  type        = string
  default     = null
}

variable "media_bucket_name" {
  description = "S3 bucket name for media (string, globally unique), or empty to derive gramps-web-media-<account-id>."
  type        = string
  default     = ""
}

variable "backup" {
  description = "AWS Backup of the data volume and media bucket (object), billed per GiB-month of recovery points. mode is local, cross_region (adds a copy in region, default us-east-2, with a second vault and key), cross_account (copies into a vault account_id owns under dest_vault_name; docs/cross-account-backup.md), or disabled. retention_days is in days (0 for remote_retention_days means the same as local); schedule is a cron or rate expression in UTC."
  type = object({
    mode                  = optional(string, "local")
    region                = optional(string, "")
    account_id            = optional(string, "")
    retention_days        = optional(number, 7)
    remote_retention_days = optional(number, 0)
    dest_vault_name       = optional(string, "gramps-web-backup-replica")
    schedule              = optional(string, "cron(0 3 * * ? *)")
  })
  default = {}
  validation {
    condition     = contains(["local", "cross_region", "cross_account", "disabled"], var.backup.mode)
    error_message = "backup.mode must be one of: local, cross_region, cross_account, disabled."
  }
  validation {
    condition     = var.backup.mode != "cross_account" || can(regex("^[0-9]{12}$", var.backup.account_id))
    error_message = "backup.mode = cross_account requires backup.account_id, a 12-digit AWS account ID."
  }
  validation {
    condition     = var.backup.mode != "cross_account" || var.backup.dest_vault_name != ""
    error_message = "backup.mode = cross_account requires backup.dest_vault_name to match the destination account's vault name."
  }
  validation {
    condition     = var.backup.retention_days >= 1 && var.backup.retention_days == floor(var.backup.retention_days)
    error_message = "backup.retention_days must be a whole number of days, at least 1."
  }
  validation {
    condition     = var.backup.remote_retention_days >= 0 && var.backup.remote_retention_days == floor(var.backup.remote_retention_days)
    error_message = "backup.remote_retention_days must be a whole number of days, where 0 matches retention_days."
  }
  validation {
    condition     = can(regex("^(cron|rate)\\(.*\\)$", var.backup.schedule))
    error_message = "backup.schedule must be an AWS Backup cron(...) or rate(...) expression."
  }
}

variable "monthly_budget_usd" {
  description = "Monthly budget in USD (number) that the status page cost panel compares spend against. Set the alerting budget itself in keel's finops module."
  type        = number
  default     = 50
  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be positive."
  }
}

variable "spot" {
  description = "Spot capacity (object). enabled runs Spot only at a fraction of the On-Demand price, and each reclaim costs an outage of a few minutes plus an alert email. allocation_strategy is price-capacity-optimized, capacity-optimized or lowest-price; rightsize needs lowest-price."
  type = object({
    enabled             = optional(bool, false)
    allocation_strategy = optional(string, "price-capacity-optimized")
  })
  default = {}
  validation {
    condition     = contains(["price-capacity-optimized", "capacity-optimized", "lowest-price"], var.spot.allocation_strategy)
    error_message = "spot.allocation_strategy must be one of: price-capacity-optimized, capacity-optimized, lowest-price."
  }
}

variable "rightsize" {
  description = "Scale-back to the cheapest Spot pool (object); off unless schedule is set. schedule is a systemd OnCalendar expression, optionally with a timezone suffix, and applies on the next instance replacement. min_uptime_hours is the churn bound between forced replacements."
  type = object({
    schedule         = optional(string)
    min_uptime_hours = optional(number, 3)
  })
  default = {}
  validation {
    condition     = var.rightsize.schedule == null || trimspace(var.rightsize.schedule) != ""
    error_message = "rightsize.schedule must be null or a systemd OnCalendar expression (see systemd.time(7))."
  }
  validation {
    condition     = var.rightsize.schedule == null || !var.spot.enabled || var.spot.allocation_strategy == "lowest-price"
    error_message = "Rightsize chases the lowest price and would undo a capacity-aware allocator, so rightsize.schedule with spot.enabled requires spot.allocation_strategy = lowest-price."
  }
  validation {
    condition     = var.rightsize.min_uptime_hours == floor(var.rightsize.min_uptime_hours) && var.rightsize.min_uptime_hours >= 1
    error_message = "rightsize.min_uptime_hours must be a whole number of hours, at least 1."
  }
}

variable "cpu_credits" {
  description = "T-instance CPU credit mode (string): standard caps CPU at baseline, unlimited bursts at extra cost."
  type        = string
  default     = "standard"
  validation {
    condition     = contains(["standard", "unlimited"], var.cpu_credits)
    error_message = "cpu_credits must be standard or unlimited."
  }
}

variable "instance_requirements" {
  description = "Override of the ASG instance spec (object), or null to derive the spec (2 vCPU, 4 GiB memory floor). See modules/compute/variables.tf for the shape."
  type = object({
    vcpu_min             = number
    vcpu_max             = optional(number, 2)
    memory_mib_min       = number
    allowed_types_arm64  = list(string)
    allowed_types_x86_64 = list(string)
  })
  default = null
}

variable "dmarc_rua" {
  description = "mailto: URI for DMARC aggregate reports (string), or empty to omit the rua tag."
  type        = string
  default     = ""
}

variable "repo_url" {
  description = "HTTPS GitHub clone URL of the repo the builds pull build/ and scripts/ from (string). Required: your fork, since the CodeConnections app installs only on accounts you control."
  type        = string
  validation {
    condition     = can(regex("^https://github\\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.repo_url))
    error_message = "repo_url must be an HTTPS GitHub clone URL (https://github.com/owner/repo[.git]) because the pipeline's owner/repo is derived from it."
  }
}

variable "source_branch" {
  description = "Branch of repo_url the builds pull (string). CodePipeline sources a branch, never a tag, so use the release-<major>.<minor> branch matching the module ref. Builds run its build/ and scripts/ with deploy permissions."
  type        = string
}

variable "gramps" {
  description = "Gramps Web build (object). version is the upstream grampsweb image tag; base_image its repository without a tag; addons are addons-source directory names baked in; web_repo and web_ref optionally replace the frontend with a fork build (web_ref pins a commit); addons_source_repo is the addons Git URL."
  type = object({
    version            = optional(string, "26.10.2")
    base_image         = optional(string, "ghcr.io/gramps-project/grampsweb")
    addons             = optional(list(string), [])
    addons_source_repo = optional(string, "https://github.com/gramps-project/addons-source.git")
    web_repo           = optional(string, "")
    web_ref            = optional(string, "")
  })
  default = {}
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.gramps.version))
    error_message = "gramps.version must be a semver-style release tag such as 26.10.2."
  }
  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9._/-]*$", var.gramps.base_image))
    error_message = "gramps.base_image must be a container image reference without a tag."
  }
  validation {
    condition     = alltrue([for a in var.gramps.addons : can(regex("^[A-Za-z0-9._-]+$", a))])
    error_message = "gramps.addons names must match ^[A-Za-z0-9._-]+$, the directory names in addons-source."
  }
  validation {
    condition     = var.gramps.web_repo == "" || var.gramps.web_ref != ""
    error_message = "gramps.web_ref is required when gramps.web_repo is set."
  }
}

variable "status" {
  description = "Operational status page at /_status (object); off unless enabled. min_role is the lowest Gramps Web role that may view it (nobody locks it). host_metrics adds disk and memory panels and a disk alarm, billed per custom metric and alarm per month. volume_metrics adds exact byte metrics, needs host_metrics and a base-AMI rebuild. cost adds a Cost Explorer panel at 0.01 USD per call on a Lambda cold start. public_reliability serves redacted uptime history at /_status/public and cannot combine with min_role nobody. The status Lambda reserves 10 concurrent executions and Lambda keeps 100 unreserved, so the account's Lambda concurrency quota must be at least 110; new accounts often start at 10, so request an increase first."
  type = object({
    enabled            = optional(bool, false)
    min_role           = optional(string, "owner")
    host_metrics       = optional(bool, false)
    volume_metrics     = optional(bool, false)
    cost               = optional(bool, false)
    public_reliability = optional(bool, false)
  })
  default = {}
  validation {
    condition     = contains(["guest", "member", "contributor", "editor", "owner", "admin", "nobody"], var.status.min_role)
    error_message = "status.min_role must be one of: guest, member, contributor, editor, owner, admin, nobody."
  }
  validation {
    condition     = !(var.status.min_role == "nobody" && var.status.public_reliability)
    error_message = "status.public_reliability cannot be true when status.min_role is nobody, because a public route would defeat the lock."
  }
  validation {
    condition     = !var.status.volume_metrics || var.status.host_metrics
    error_message = "status.volume_metrics requires status.host_metrics, because the byte series ship inside the host metrics payload."
  }
}

variable "frontend" {
  description = "Gramps Web browser config, window.grampsjsConfig (object). Empty strings keep the upstream default and omit the key. The map style fields are MapLibre style URLs for the light map, dark map and OpenHistoricalMap overlay."
  type = object({
    hide_dna_link        = optional(bool, false)
    login_redirect       = optional(string, "")
    map_base_style_light = optional(string, "")
    map_base_style_dark  = optional(string, "")
    map_ohm_style        = optional(string, "")
  })
  default = {}
  validation {
    condition = alltrue([
      for v in [var.frontend.map_base_style_light, var.frontend.map_base_style_dark, var.frontend.map_ohm_style] :
      v == "" || can(regex("^https?://", v))
    ])
    error_message = "frontend map style fields must be empty (upstream default) or a URL starting with http:// or https://."
  }
}

variable "api" {
  description = "Non-secret Gramps Web API settings (object). registration is open, unlisted (open endpoint, no sign-up link) or closed. tree_id is required when tree is not main. Unset (null) fields keep upstream defaults. extra passes other upstream keys without the GRAMPSWEB_ prefix and is stored in a plain SSM parameter, so never put secrets in it."
  type = object({
    tree                     = optional(string, "main")
    tree_id                  = optional(string)
    registration             = optional(string, "open")
    disable_telemetry        = optional(bool, false)
    pillow_max_image_pixels  = optional(number)
    max_thumbnail_file_bytes = optional(number)
    log_level                = optional(string)
    rate_limit_media_archive = optional(string)
    cors_origins             = optional(string)
    extra                    = optional(map(string), {})
  })
  default = {}

  validation {
    condition     = contains(["open", "unlisted", "closed"], var.api.registration)
    error_message = "api.registration must be one of: open, unlisted, closed."
  }

  validation {
    condition     = var.api.tree == "main" || var.api.tree_id != null
    error_message = "api.tree_id is required when api.tree is not main, because changing the tree alone on a live deployment silently creates an empty tree. Set tree_id to the current tree's directory name first."
  }

  validation {
    condition     = alltrue([for k in keys(var.api.extra) : can(regex("^[A-Z][A-Z0-9_]*(__[A-Za-z0-9_]+)*$", k))])
    error_message = "api.extra keys must be bare upstream settings in upper snake case, such as CORS_ORIGINS or CELERY_CONFIG__broker_url."
  }

  validation {
    condition = alltrue([
      for k in keys(var.api.extra) :
      !contains([
        "TREE", "TREE_ID", "SECRET_KEY", "USER_DB_URI", "MEDIA_BASE_DIR", "STATIC_PATH", "BASE_URL",
        "SEARCH_INDEX_DB_URI", "RATELIMIT_STORAGE_URI", "REGISTRATION_DISABLED", "DISABLE_TELEMETRY",
        "PILLOW_MAX_IMAGE_PIXELS", "MAX_THUMBNAIL_FILE_BYTES", "LOG_LEVEL", "RATE_LIMIT_MEDIA_ARCHIVE",
        "CORS_ORIGINS", "DEFAULT_FROM_EMAIL", "BACKUP_DIR",
      ], k) &&
      !startswith(k, "EMAIL_") &&
      !startswith(k, "CELERY_CONFIG") &&
      !startswith(k, "LLM_") &&
      !startswith(k, "OIDC_")
    ])
    error_message = "api.extra cannot set a key this module derives: TREE, TREE_ID, REGISTRATION_DISABLED, DISABLE_TELEMETRY, PILLOW_MAX_IMAGE_PIXELS, MAX_THUMBNAIL_FILE_BYTES, LOG_LEVEL, RATE_LIMIT_MEDIA_ARCHIVE and CORS_ORIGINS have api fields; SECRET_KEY, USER_DB_URI, MEDIA_BASE_DIR, STATIC_PATH, BASE_URL, SEARCH_INDEX_DB_URI, RATELIMIT_STORAGE_URI, BACKUP_DIR are fixed; DEFAULT_FROM_EMAIL and EMAIL_* come from SES; CELERY_CONFIG* is queue wiring; LLM_* is the llm variable; OIDC_* is reserved."
  }

  validation {
    condition     = alltrue([for k in keys(var.api.extra) : !can(regex("_PASSWORD$|_SECRET$|_API_KEY$|_TOKEN$|_DSN$", k))])
    error_message = "api.extra keys must not look like secrets (_PASSWORD, _SECRET, _API_KEY, _TOKEN, _DSN) because the values land in a plain SSM String parameter."
  }

  validation {
    condition     = alltrue([for v in values(var.api.extra) : !strcontains(v, "\n")])
    error_message = "api.extra values must not contain a newline because each becomes one KEY=value line."
  }

  validation {
    condition     = var.api.pillow_max_image_pixels == null || (var.api.pillow_max_image_pixels >= 0 && var.api.pillow_max_image_pixels == floor(var.api.pillow_max_image_pixels))
    error_message = "api.pillow_max_image_pixels must be null or a non-negative integer."
  }

  validation {
    condition     = var.api.max_thumbnail_file_bytes == null || (var.api.max_thumbnail_file_bytes >= 0 && var.api.max_thumbnail_file_bytes == floor(var.api.max_thumbnail_file_bytes))
    error_message = "api.max_thumbnail_file_bytes must be null or a non-negative integer."
  }

  validation {
    condition     = var.api.log_level == null || contains(["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"], var.api.log_level)
    error_message = "api.log_level must be null or one of: DEBUG, INFO, WARNING, ERROR, CRITICAL."
  }

  validation {
    condition     = var.api.cors_origins != "*"
    error_message = "api.cors_origins must not be a wildcard because this is a single-origin deployment; name the specific origins."
  }
}

variable "llm" {
  description = "AI chat assistant on Bedrock (object); off unless enabled, and billed per token when on. model_id is the Bedrock model or inference-profile ID without the bedrock: prefix; region is the invocation region (empty for the module's region). max_requests, max_tokens and max_context_length bound each chat run; system_prompt overrides the agent prompt. hourly_token_alarm is the token count per hour that alarms to alert_email, 0 to disable."
  type = object({
    enabled            = optional(bool, false)
    model_id           = optional(string, "us.anthropic.claude-haiku-4-5-20251001-v1:0")
    region             = optional(string, "")
    max_requests       = optional(number, 15)
    max_tokens         = optional(number, 200000)
    max_context_length = optional(number, 50000)
    system_prompt      = optional(string, "")
    hourly_token_alarm = optional(number, 3000000)
  })
  default = {}
  validation {
    condition     = can(regex("^[A-Za-z0-9._:-]+$", var.llm.model_id)) && !startswith(var.llm.model_id, "bedrock:")
    error_message = "llm.model_id must be a bare Bedrock model or inference-profile ID."
  }
  validation {
    condition = alltrue([
      for v in [var.llm.max_requests, var.llm.max_tokens, var.llm.max_context_length] :
      v == floor(v) && v > 0
    ])
    error_message = "llm.max_requests, llm.max_tokens and llm.max_context_length must be positive integers."
  }
  validation {
    condition     = !strcontains(var.llm.system_prompt, "\n")
    error_message = "llm.system_prompt must not contain a newline because it becomes one KEY=value line."
  }
}

variable "additional_origins" {
  description = "Extra CloudFront origins on the primary distribution (map of origin ID to object), for serving content beside the app. See modules/edge/variables.tf for the shape."
  type = map(object({
    domain_name              = string
    origin_access_control_id = optional(string)
  }))
  default = {}
}

variable "additional_cache_behaviors" {
  description = "Extra ordered cache behaviors on the primary distribution (list of objects) that route paths to additional_origins. See modules/edge/variables.tf for the shape and the paths that must not be overlapped."
  type = list(object({
    path_pattern             = string
    target_origin_id         = string
    allowed_methods          = optional(list(string), ["GET", "HEAD"])
    cache_policy_id          = optional(string, "658327ea-f89d-4fab-a63d-7e88639e58f6")
    origin_request_policy_id = optional(string)
    function_associations = optional(list(object({
      event_type   = string
      function_arn = string
    })), [])
  }))
  default = []
}
