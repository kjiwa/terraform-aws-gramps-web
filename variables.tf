variable "env" {
  description = "Environment name. Must match the terraform/config/stack/<env> directory this config lives in. Flows into resource names that would otherwise be ambiguous across environments and into the Env default tag. One AWS account per environment; two envs in one account would collide on the fixed resource names (IAM roles, ECR repo, ASG, pipeline)."
  type        = string
}

variable "account_id" {
  description = "AWS account ID this environment deploys to. Guards against applying an env with the wrong credentials (the provider refuses any other account). Empty disables the guard."
  type        = string
  default     = ""
  validation {
    condition     = var.account_id == "" || can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID or empty."
  }
}

variable "active" {
  description = "If false, the environment sleeps: the ASG holds zero instances and the availability canary and its alarm notifications are suspended, while all state (EBS data volume, S3 media, DNS, certificates, ECR images, the last CodeDeploy revision) is retained. Waking (flip to true, apply) launches an instance that self-deploys the last revision; expect roughly five minutes to serving. Sleeping saves the instance cost; the retained pieces cost a few dollars a month. Deploys require an awake environment."
  type        = bool
  default     = true
}

variable "primary_region" {
  description = "Primary AWS region for workload resources."
  type        = string
  default     = "us-east-1"
}

variable "az" {
  description = "Availability zone for the EC2 instance and EBS data volume (EBS is AZ-scoped). Null (the default) uses the region's first available AZ. Set it to pin -- and do pin it on an existing deployment before changing anything else, because a different AZ replaces the subnet and data volume (docs/az-move.md is the safe path)."
  type        = string
  default     = null
}

variable "ami_ids" {
  description = "Per-architecture base AMI IDs from the gramps-web-base Packer builds (keys: arm64, x86_64). Pinned so a rebuild rolls out nothing until this is bumped and applied (new launch template version + instance refresh); rollback is reverting the bump."
  type        = map(string)
  validation {
    condition     = alltrue([for v in var.ami_ids : can(regex("^ami-[0-9a-f]+$", v))])
    error_message = "ami_ids values must be AMI IDs matching ^ami-[0-9a-f]+$."
  }
}

variable "primary_domain" {
  description = "The canonical apex domain. Must be a key of domains; every other domain (and every www.) 301s to it."
  type        = string
  validation {
    condition     = contains(keys(var.domains), var.primary_domain)
    error_message = "primary_domain must be one of the keys of domains."
  }
}

variable "domains" {
  description = "Apex domains served; the one named by primary_domain is canonical and the rest 301 to it. dnssec provisions a KSK and surfaces the DS record for that zone."
  type = map(object({
    dnssec = optional(bool, false)
  }))
  validation {
    condition     = alltrue([for k in keys(var.domains) : k == lower(k)])
    error_message = "Domain names must be lowercase (they flow into S3 bucket names)."
  }
}

variable "site_title" {
  description = "Human-facing site name. Empty string falls back to the primary domain."
  type        = string
  default     = ""
}

variable "data_volume_snapshot_id" {
  description = "EC2 snapshot ID to create the data volume from. First apply only -- snapshot_id is ForceNew and the volume carries prevent_destroy, so setting this on a live deployment plans a replace that errors instead of adopting it; that is the guard working, not a bug. For rebuilding a fresh environment from a disaster-recovery snapshot (scripts/restore.sh offsite, then snapshot the result -- see docs/restore.md). Putting a restored volume into a running environment is docs/az-move.md (adopt), not this. The media bucket has no equivalent: an S3 restore writes into a bucket that already exists, so that rebuild path is apply first, then scripts/restore.sh into the new bucket."
  type        = string
  default     = null
}

variable "media_bucket_name" {
  description = "S3 bucket name for Gramps media. Globally unique. Empty string derives gramps-web-media-<account-id>."
  type        = string
  default     = ""
}

variable "backup" {
  description = <<-EOT
    Where the irreplaceable data is backed up -- the EBS data volume (tree DB,
    search index, users, secret) and the S3 media bucket (photo/document
    originals), both through one AWS Backup plan. mode picks the destination:

      local        - daily recovery points in a vault in this account/region
                     only (the stable default).
      cross_region - also copy each recovery point to a vault in region
                     (default us-east-2). Region-failure DR, same account;
                     non-destructive to set up.
      cross_account - also copy each recovery point to a vault another account
                     in the org owns (blast-radius isolation: a copy the source
                     account cannot delete). Point region at a non-primary
                     region and this subsumes cross_region rather than sitting
                     beside it. Requires account_id, a matching
                     backup-account apply in that account (scripts/tf.sh
                     backup-account/<instance> apply), cross-account backup
                     enabled org-wide from the management account, and -- for a
                     deployment that predates aws_kms_key.data -- a one-time
                     re-key of the volume. AWS cannot copy snapshots encrypted
                     under the default aws/ebs key, whose policy is immutable.
                     Ordered, gated procedure: docs/cross-account-backup.md.
      disabled     - no scheduled backups at all.

    region overrides the copy destination's region. retention_days sets local
    retention; remote_retention_days sets the copies' (0 = same as local). The
    split is deliberate: local is the fast restore path, remote is the one that
    has to still be there after a bad month. dest_vault_name must match the
    backup account's vault_name -- the destination vault ARN is constructed from
    account_id + region + this name rather than pasted in, so the two names are
    a contract. Only cross_account reads account_id / dest_vault_name. schedule
    is an AWS Backup cron(...) or rate(...) expression, evaluated in UTC; the
    default is a daily run at 03:00 UTC.
  EOT
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
    error_message = "backup.mode = cross_account requires backup.account_id (a 12-digit AWS account ID)."
  }
  validation {
    condition     = var.backup.mode != "cross_account" || var.backup.dest_vault_name != ""
    error_message = "backup.mode = cross_account requires backup.dest_vault_name (matching the backup account's vault_name)."
  }
  validation {
    condition     = var.backup.retention_days >= 1 && var.backup.retention_days == floor(var.backup.retention_days)
    error_message = "backup.retention_days must be a whole number of days, at least 1."
  }
  validation {
    condition     = var.backup.remote_retention_days >= 0 && var.backup.remote_retention_days == floor(var.backup.remote_retention_days)
    error_message = "backup.remote_retention_days must be a whole number of days (0 to match retention_days)."
  }
  validation {
    condition     = can(regex("^(cron|rate)\\(.*\\)$", var.backup.schedule))
    error_message = "backup.schedule must be an AWS Backup cron(...) or rate(...) expression."
  }
}

variable "data_volume_gb" {
  description = "Size of the EBS data volume in GiB (gp3), holding the tree database, search index, users, and secrets. 5 GiB is roughly 74x the measured tree size. Raising it is an in-place ModifyVolume; lowering it is not (scripts/azmove.sh shrink)."
  type        = number
  default     = 5
  validation {
    condition     = var.data_volume_gb >= 1
    error_message = "data_volume_gb must be at least 1."
  }
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget in USD for the FinOps guardrail. Notifications email alert_email at 80% of actual and 100% of forecasted spend. Set it a little above steady-state so normal months stay quiet but a runaway trips it."
  type        = number
  default     = 50
  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be positive."
  }
}

variable "spot_enabled" {
  description = "If true, the ASG uses Spot exclusively, roughly a third of the On-Demand price, paid for in reclaims that each cost an outage of about 5 minutes (measured median; p90 7 minutes) plus an interruption-alert email. The default is On-Demand so a fresh deployment is stable and quiet until Spot is chosen deliberately."
  type        = bool
  default     = false
}

variable "spot_allocation_strategy" {
  description = "Spot allocation strategy: lowest-price takes the cheapest pool regardless of depth and was measured at roughly one reclaim a day in a bad week; price-capacity-optimized weighs price and capacity depth at a similar price (reclaim rate unmeasured); capacity-optimized takes the deepest pool regardless of price. Only lowest-price pairs with rightsize_schedule."
  type        = string
  default     = "price-capacity-optimized"
  validation {
    condition     = contains(["price-capacity-optimized", "capacity-optimized", "lowest-price"], var.spot_allocation_strategy)
    error_message = "spot_allocation_strategy must be one of: price-capacity-optimized, capacity-optimized, lowest-price."
  }
}

variable "cpu_credits" {
  description = "T-instance CPU credit mode. 'standard' caps CPU at baseline once earned credits are exhausted (no surprise charges); 'unlimited' allows sustained bursting at extra cost."
  type        = string
  default     = "standard"
  validation {
    condition     = contains(["standard", "unlimited"], var.cpu_credits)
    error_message = "cpu_credits must be 'standard' or 'unlimited'."
  }
}

variable "rightsize_schedule" {
  description = "systemd OnCalendar expression for the rightsize check, or null (the default) to leave rightsize off. Rightsize is the scale-back to the cheapest eligible Spot pool by price (build/ami/rightsize-watchdog.sh); it only pairs with spot_allocation_strategy = lowest-price, since it would undo the pool choice of a capacity-aware allocator. Accepts a timezone suffix, e.g. \"*-*-* 17:00:00 America/New_York\", which tracks DST where a fixed UTC hour would not. A daily schedule is the stable choice; a cost-sensitive deployment can go as often as hourly (e.g. \"*-*-* *:47:00\") because the watchdog's uptime cooldown bounds replacement churn -- the schedule only sets how quickly a recovered cheap pool is reclaimed. Each replacement is still a blip, so with a daily schedule pick the hour when that costs least: after your region's demand surge if reclaims cluster at working hours (so the chosen pool survives the day), or a reader-quiet hour otherwise. Applied by user-data as a systemd timer drop-in, so unlike the other watchdog tunables (status.host_metrics/volume_metrics, instance_requirements, rightsize_min_uptime_hours), a change here takes effect only on the next instance replacement, not on the watchdogs' own poll. Only acts on Spot instances; On-Demand deployments never rightsize."
  type        = string
  default     = null
  nullable    = true
  validation {
    condition     = var.rightsize_schedule == null || trimspace(var.rightsize_schedule) != ""
    error_message = "rightsize_schedule must be null or a systemd OnCalendar expression (see systemd.time(7))."
  }
  validation {
    condition     = var.rightsize_schedule == null || !var.spot_enabled || var.spot_allocation_strategy == "lowest-price"
    error_message = "Rightsize replaces instances to chase the lowest price and would undo the pool choice of a capacity-aware allocator, so with spot_enabled = true and rightsize_schedule set, spot_allocation_strategy must be lowest-price."
  }
}

variable "rightsize_min_uptime_hours" {
  description = "Minimum instance uptime before the rightsize watchdog may force a replacement. This is the churn bound for aggressive rightsize_schedule values: a failed rightsize (allocation landed on a big type again) restarts the clock on the replacement instance, so worst-case replacements are 24/this per day no matter how often the timer fires. Irrelevant under a daily schedule (24h between ticks always exceeds it)."
  type        = number
  default     = 3
  validation {
    condition     = var.rightsize_min_uptime_hours == floor(var.rightsize_min_uptime_hours) && var.rightsize_min_uptime_hours >= 1
    error_message = "rightsize_min_uptime_hours must be a whole number of hours, at least 1."
  }
}

variable "dmarc_rua" {
  description = "Optional mailto: URI for DMARC aggregate reports. Empty string omits the rua tag."
  type        = string
  default     = ""
}

variable "alert_email" {
  description = "Email address that receives site DOWN/RECOVERED notices. Confirm the SNS subscription email after the first apply."
  type        = string
  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "log_retention_days" {
  description = "Days to retain audit logs (CloudTrail + S3 access logs) before expiry. SOC2 commonly wants at least a year of audit trail. Also sets the S3 Object-Lock GOVERNANCE window on the log bucket."
  type        = number
  default     = 365
}

variable "instance_requirements" {
  description = "Wholesale override of the ASG instance spec. Leave null (the default) to let the compute module derive sizing from the feature set: the AI assistant flag decides the memory floor, and so whether 2-GiB smalls are eligible. Set only to pin the vCPU/memory range or eligibility; see modules/compute/variables.tf for the shape and semantics."
  type = object({
    vcpu_min             = number
    vcpu_max             = optional(number, 2)
    memory_mib_min       = number
    allowed_types_arm64  = list(string)
    allowed_types_x86_64 = list(string)
  })
  default = null
}

variable "repo_url" {
  description = "HTTPS clone URL of this infra repo; the app pipeline and the builds pull their build/<component>/ directory and scripts/ from it. Point at your fork."
  type        = string
  validation {
    condition     = can(regex("^https://github\\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.repo_url))
    error_message = "repo_url must be an HTTPS GitHub clone URL (https://github.com/owner/repo[.git]); the pipeline's owner/repo id is derived from it."
  }
}

variable "source_branch" {
  description = "Branch the builds pull from repo_url."
  type        = string
  default     = "main"
}

variable "status" {
  description = "Operational status page at /_status. enabled: on, provisions the status Lambda + Function URL and the CloudFront behaviors that route to it; off, none of it exists and /_status* falls through to the app origin. min_role: lowest Gramps Web role (guest, member, contributor, editor, owner, admin) allowed to view the full page at /_status/data; default owner. nobody locks the authenticated page to everyone (a runtime lock, distinct from enabled = false) -- see the validation below for how it interacts with public_reliability. host_metrics (default false): adds a panel reading the instance's disk/memory custom metrics, and an alarm emailing alert_email when the data volume passes 85% used; a few cents/month in CloudWatch custom-metric charges, plus $0.10 per alarm metric per month for the alarm (1 metric, or 2 with volume_metrics). volume_metrics (default false): switches the Storage panel's disk reading from a single-volume integer percent to exact used/total bytes for both the data volume and root, requires host_metrics (the byte series ships inside its payload branch), and only takes effect after the next base-AMI rebuild (build/ami/health-watchdog.sh, the publisher, is Packer-baked, not hot-reloaded) -- turning it on ahead of a rebuild is safe and free, since an instance on the old AMI just keeps publishing the percent series. host_metrics adds 2 custom metrics, volume_metrics 4 more. CloudWatch's always-free 10 custom metrics / 10 alarms is an org-wide allowance under consolidated billing, not per-account -- a second env in a sibling account draws on the same pool, and each metric past the shared 10 costs $0.30/month and each alarm metric $0.10. Whether this is free depends on what else the organization is running, not on this account in isolation. cost (default false): adds a Cost Explorer month-to-date panel, cached for 1 hour per warm Lambda container; otherwise $0.01 per Cost Explorer call on every cold start. public_reliability (default false): also serves GET /_status/public -- uptime and incident history only, instance detail redacted -- computed purely from CloudWatch/Logs with no Gramps Web dependency, so it renders even while the app itself is down. Publicly cacheable at the edge (CachingOptimized; ~60s effective staleness once the kill switch is flipped off); costs nothing beyond the existing availability canary. Cannot be combined with min_role = nobody, which exists specifically to make the page inaccessible to everyone -- a public route would walk straight past that lock."
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
    error_message = "status.public_reliability cannot be true when status.min_role is nobody: nobody exists to lock the page to everyone, and a public route would defeat that lock."
  }
  validation {
    condition     = !(var.status.volume_metrics && !var.status.host_metrics)
    error_message = "status.volume_metrics requires status.host_metrics: the byte series are read and shipped by host_metrics()'s own payload branch, so there is no path for them to reach the page with that panel off."
  }
}

variable "gramps_web_version" {
  description = "Upstream grampsweb image tag the app pipeline builds from (e.g. 26.10.2). The Gramps-core version and addon branch are derived from it at build time. Bump here, apply, then run scripts/deploy.sh gramps."
  type        = string
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.gramps_web_version))
    error_message = "gramps_web_version must be a semver-style release tag (e.g. 26.10.2)."
  }
}

variable "gramps_base_image" {
  description = "Upstream grampsweb image the app image derives FROM; tagged with gramps_web_version at build time."
  type        = string
  default     = "ghcr.io/gramps-project/grampsweb"
  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9._/-]*$", var.gramps_base_image))
    error_message = "gramps_base_image must be a plausible container image reference (registry/repo, no tag)."
  }
}

variable "gramps_addons" {
  description = "Gramps addons baked into the app image: directory names as they appear at the root of addons-source (the branch is derived from the running Gramps version). Empty list builds the plain upstream image. Change here, apply, then run scripts/deploy.sh gramps."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for a in var.gramps_addons : can(regex("^[A-Za-z0-9._-]+$", a))])
    error_message = "Addon names must match ^[A-Za-z0-9._-]+$ (directory names in addons-source)."
  }
}

variable "gramps_web_repo" {
  description = "Optional gramps-web (frontend) repo whose built dist/ replaces the frontend baked into the upstream image; the release-pinned API underneath is unchanged. Empty (the default) ships the upstream frontend. Set to a fork to verify a frontend fix: fill this and gramps_web_ref, apply, run scripts/deploy.sh gramps; revert by emptying both and deploying again."
  type        = string
  default     = ""
}

variable "gramps_web_ref" {
  description = "Git ref of gramps_web_repo to build; pin a commit SHA for reproducible builds. Base it on the deployed release's frontend (the v<gramps_web_version> tag), not main: the API in the base image is release-pinned and a newer frontend may call endpoints it lacks."
  type        = string
  default     = ""
  validation {
    condition     = var.gramps_web_repo == "" || var.gramps_web_ref != ""
    error_message = "gramps_web_ref is required when gramps_web_repo is set."
  }
}

variable "addons_source_repo" {
  description = "Git URL of the Gramps addons-source repo (fork point for custom addons)."
  type        = string
  default     = "https://github.com/gramps-project/addons-source.git"
}

variable "frontend" {
  description = "Gramps Web's frontend runtime config (window.grampsjsConfig), authored whole by Terraform and rendered into /app/static/config.js via the frontend-config SSM parameter (terraform/modules/compute/ssm.tf) -- the shell no longer parses or escapes any of this. hide_dna_link maps directly to hideDNALink. Leaving login_redirect / map_base_style_light / map_base_style_dark / map_ohm_style at their default empty string means \"use the upstream default\", and the corresponding key is omitted from config.js entirely -- Terraform never writes an empty value for these. hideRegisterLink is also present in config.js, but it is not a field here -- it derives from api.registration, since this stack's single tree and single frontend mean the endpoint and its link always move together (see that variable's mode table). map_base_style_light / map_base_style_dark / map_ohm_style are MapLibre style URLs for, respectively, the light-theme map, the dark-theme map, and the OpenHistoricalMap overlay."
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
    error_message = "frontend.map_base_style_light, frontend.map_base_style_dark, and frontend.map_ohm_style must be empty (upstream default) or a URL starting with http:// or https://."
  }
}

variable "api" {
  description = <<-EOT
    Non-secret Gramps Web API (backend) options that have no dedicated
    variable elsewhere in this file, plus the escape hatch for everything
    else. Values reach the app through the gramps-env SSM parameter (a plain
    String, not a SecureString), consumed by docker compose's env_file: --
    so nothing that belongs in here may be a secret.

    registration (default "open") controls both GRAMPSWEB_REGISTRATION_DISABLED
    and the frontend hideRegisterLink key -- one field so the API and the UI
    cannot disagree about whether sign-up is open. Upstream documents these as
    two independent settings because its frontend and backend are
    independently deployable and, in a multi-tree install, one frontend fronts
    many trees; this stack is single-tree with one frontend and one API
    configured from one tfvars, so the two always move together:

      open      - REGISTRATION_DISABLED=false, hideRegisterLink absent. The
                  sign-up form is advertised on the login page. A
                  self-registered account still lands in Gramps Web's own
                  "disabled" role and needs both email confirmation and an
                  owner manually promoting it out of that role before it can
                  log in -- so this is a request queue, not open access, which
                  is what makes it a reasonable default.
      unlisted  - REGISTRATION_DISABLED=false, hideRegisterLink=true. The
                  endpoint stays open but nothing on the login page points at
                  it -- share the sign-up URL directly. This is upstream's own
                  documented pattern for multi-tree installs
                  (https://www.grampsweb.org/install_setup/frontend-config/,
                  https://www.grampsweb.org/user-guide/registration/), reused
                  here as the "not advertised" middle ground.
      closed    - REGISTRATION_DISABLED=true, hideRegisterLink=true. The
                  owner creates every account.

    tree (default "main") and tree_id are TREE / TREE_ID. tree_id is required
    whenever tree is changed from the default -- see the validation below for
    why.

    disable_telemetry (default false) drives GRAMPSWEB_DISABLE_TELEMETRY
    directly. pillow_max_image_pixels / max_thumbnail_file_bytes (default
    null) are GRAMPSWEB_PILLOW_MAX_IMAGE_PIXELS /
    GRAMPSWEB_MAX_THUMBNAIL_FILE_BYTES; null means "leave unset" (upstream's
    own default applies) and omits the key from gramps-env entirely.
    log_level is GRAMPSWEB_LOG_LEVEL. rate_limit_media_archive is
    GRAMPSWEB_RATE_LIMIT_MEDIA_ARCHIVE -- upstream's "1 per day" default is
    restrictive for a family site. cors_origins is GRAMPSWEB_CORS_ORIGINS,
    named explicitly (rather than left to extra) so it can be validated
    against "*", which is unsafe on a single-origin CloudFront deployment.

    extra (default {}) is the escape hatch for every other non-secret
    Gramps Web API setting this stack does not name explicitly: bare upstream
    keys (the GRAMPSWEB_ prefix is added automatically), rendered verbatim as
    KEY=value lines into the same gramps-env parameter, sorted by key for a
    stable plan diff. Three things to know before using it: (a) values land
    in git (tfvars) and in a plain SSM String parameter -- nothing here may be
    a secret, and the validation below rejects secret-shaped key names; (b)
    keys the stack already derives are rejected by validation below; (c)
    nested upstream settings use the "__" convention, e.g.
    CELERY_CONFIG__broker_url -- the sub-key after __ may be lower/mixed case,
    matching upstream's own dict keys.
  EOT
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
    error_message = "api.tree_id is required when api.tree is changed from the default: changing api.tree alone on a live deployment silently creates a new empty tree rather than renaming the existing one. Find the current tree's directory name via GET /api/trees/-, set api.tree_id to it, then change api.tree."
  }

  validation {
    condition     = alltrue([for k in keys(var.api.extra) : can(regex("^[A-Z][A-Z0-9_]*(__[A-Za-z0-9_]+)*$", k))])
    error_message = "api.extra keys must be bare Gramps Web API settings in upper snake case (the GRAMPSWEB_ prefix is added automatically), e.g. CORS_ORIGINS or CELERY_CONFIG__broker_url (nested settings use __; the sub-key after __ may be lower/mixed case, matching upstream's own dict keys)."
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
    error_message = "api.extra cannot set a key this stack already derives elsewhere, or OIDC_* (reserved for an oidc block). TREE/TREE_ID/REGISTRATION_DISABLED/DISABLE_TELEMETRY/PILLOW_MAX_IMAGE_PIXELS/MAX_THUMBNAIL_FILE_BYTES/LOG_LEVEL/RATE_LIMIT_MEDIA_ARCHIVE/CORS_ORIGINS: have their own api.* fields above -- one way to set each, not two. SECRET_KEY/USER_DB_URI/MEDIA_BASE_DIR/STATIC_PATH/BASE_URL/SEARCH_INDEX_DB_URI/RATELIMIT_STORAGE_URI: architecture constants (this stack's single tree, or upstream image defaults) that this stack does not vary. DEFAULT_FROM_EMAIL/EMAIL_*: module.email's SES setup. CELERY_CONFIG*: derived queue wiring for the valkey sidecar. LLM_*: the llm variable."
  }

  validation {
    condition     = alltrue([for k in keys(var.api.extra) : !can(regex("_PASSWORD$|_SECRET$|_API_KEY$|_TOKEN$|_DSN$", k))])
    error_message = "api.extra keys must not look like secrets (_PASSWORD/_SECRET/_API_KEY/_TOKEN/_DSN) -- extra values land in git (tfvars) and a plaintext SSM String parameter."
  }

  validation {
    condition     = alltrue([for v in values(var.api.extra) : !strcontains(v, "\n")])
    error_message = "api.extra values must not contain a newline (breaks the KEY=value line format)."
  }

  validation {
    condition     = var.api.pillow_max_image_pixels == null || (var.api.pillow_max_image_pixels >= 0 && var.api.pillow_max_image_pixels == floor(var.api.pillow_max_image_pixels))
    error_message = "api.pillow_max_image_pixels must be null (unset) or a non-negative integer."
  }

  validation {
    condition     = var.api.max_thumbnail_file_bytes == null || (var.api.max_thumbnail_file_bytes >= 0 && var.api.max_thumbnail_file_bytes == floor(var.api.max_thumbnail_file_bytes))
    error_message = "api.max_thumbnail_file_bytes must be null (unset) or a non-negative integer."
  }

  validation {
    condition     = var.api.log_level == null || contains(["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"], var.api.log_level)
    error_message = "api.log_level must be null (unset) or one of: DEBUG, INFO, WARNING, ERROR, CRITICAL."
  }

  validation {
    condition     = var.api.cors_origins != "*"
    error_message = "api.cors_origins must not be \"*\" -- this is a single-origin CloudFront deployment; allowing any origin defeats CORS protection. Set it to the specific origin(s) that need it."
  }
}

variable "llm" {
  description = "AI chat assistant (Bedrock + pydantic-ai). enabled is the feature toggle: on, the app gets the chat config, the instance role gets the Bedrock grant, and the FilterRules addon (a chat dependency; the assistant warns when it is absent) is baked into the image automatically; off, none of that exists and the deployment incurs no Bedrock cost. model_id is the Bedrock model or inference-profile ID, without the 'bedrock:' provider prefix; region is where it is invoked (empty = primary_region; set only when quotas force another region). The instance's Bedrock IAM grants are derived from these, so this is the only place the model is named. The max_* limits default to the upstream defaults: max_requests caps agent round-trips per turn (raise if the agent 429s on complex questions), max_tokens is the cumulative input+output token budget per run and doubles as the per-question spend ceiling, max_context_length is the per-tool-result character budget for tree context (raise if answers lack detail). system_prompt (default empty) overrides the chat agent's system prompt (GRAMPSWEB_LLM_SYSTEM_PROMPT), emitted into gramps-env only when non-empty; like the rest of this block it is inert while enabled is false."
  type = object({
    enabled            = optional(bool, false)
    model_id           = optional(string, "us.anthropic.claude-haiku-4-5-20251001-v1:0")
    region             = optional(string, "")
    max_requests       = optional(number, 15)
    max_tokens         = optional(number, 200000)
    max_context_length = optional(number, 50000)
    system_prompt      = optional(string, "")

    # CloudWatch alarm on total Bedrock tokens (input+output) in a rolling hour,
    # into a dedicated SNS topic in the model's invocation region (alarm actions
    # must target a same-region topic, so it cannot reuse module.audit's). This
    # is the same-hour cost tripwire the $-budget cannot be: Budgets/Anomaly read
    # billing data that lags 8-24h, so a runaway chat loop would burn the month
    # before the budget notices. Sized in tokens, not dollars, because that is
    # what the metric reports; 3M tokens/hr is roughly near the monthly budget
    # on typical pricing so a runaway loop alarms within the hour. Lower it if
    # steady-state testing stays well under; 0 disables the alarm.
    hourly_token_alarm = optional(number, 3000000)
  })
  default = {}
  validation {
    condition     = can(regex("^[A-Za-z0-9._:-]+$", var.llm.model_id))
    error_message = "llm.model_id must be a bare Bedrock model/inference-profile ID."
  }
  validation {
    condition = alltrue([
      for v in [var.llm.max_requests, var.llm.max_tokens, var.llm.max_context_length] :
      v == floor(v) && v > 0
    ])
    error_message = "llm max_requests, max_tokens, and max_context_length must be positive integers."
  }
  validation {
    condition     = !strcontains(var.llm.system_prompt, "\n")
    error_message = "llm.system_prompt must not contain a newline (it becomes a single KEY=value line in gramps-env)."
  }
}
