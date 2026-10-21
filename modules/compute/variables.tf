variable "env" {
  description = "Environment name. Disambiguates per-env resources whose names are not already account-scoped constants: the SSM parameter paths and the CodeDeploy deployment group."
  type        = string
}

variable "ami_ids" {
  description = "Per-architecture base AMI IDs (gramps-web-base Packer builds), pinned in tfvars. One launch template per architecture binds to each; see launch_template.tf for how to list candidates."
  type        = map(string)
  validation {
    condition     = sort(keys(var.ami_ids)) == tolist(["arm64", "x86_64"])
    error_message = "ami_ids must contain exactly the keys \"arm64\" and \"x86_64\"."
  }
}

variable "active" {
  description = "If false the ASG holds zero instances (environment asleep). Wake by flipping to true and applying; the new instance self-deploys the last CodeDeploy revision."
  type        = bool
}

variable "subnet_ids" {
  description = "Public subnet IDs for the ASG (module.network's subnet_ids)."
  type        = list(string)
}

variable "origin_sg_id" {
  description = "Security group ID for the EC2 instance."
  type        = string
}

variable "ebs_volume_id" {
  description = "EBS data volume ID. user-data attaches it by ID at boot and finds the block device by NVMe controller serial."
  type        = string
}

variable "ebs_volume_arn" {
  description = "EBS data volume ARN. Scoped in AttachVolume IAM policy."
  type        = string
}

variable "media_bucket_name" {
  description = "S3 media bucket name."
  type        = string
}

variable "media_bucket_arn" {
  description = "S3 media bucket ARN. Used in IAM policy."
  type        = string
}

variable "ebs_kms_key_arn" {
  description = "CMK ARN encrypting the data volume, or null when the volume uses the AWS-managed aws/ebs key (every backup.mode except cross_account). Non-null grants the instance role use of the key plus kms:CreateGrant, without which user-data's AttachVolume fails at boot with CustomerKeyHasBeenRevoked -- aws/ebs needs no such grant, so this is only load-bearing once the volume is re-keyed."
  type        = string
  default     = null
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

variable "instance_requirements" {
  description = "Wholesale override of the instance spec for the ASG mixed instances policy. null (the default) derives the spec from the feature set -- the AI assistant decides the memory floor -- and admits every Nitro 2-vCPU type at or above it, including families released later (see locals in asg.tf). Set only to pin the vCPU/memory floor or eligibility; all-or-nothing so the floor and the type lists cannot drift apart (a floor above a listed type's memory silently filters that type out). Shared vCPU range and memory floor (vcpu_max defaults to 2, which bounds the cost when the cheap pools are out of capacity); allowed instance types are per-architecture (each must list only types of its arch), and an empty list means no allow-list for that arch (every Nitro type meeting the floor, accelerators excluded). The rightsize watchdog moves the instance to the cheapest eligible Spot pool by price, so pinning restricts where it can land."
  type = object({
    vcpu_min             = number
    vcpu_max             = optional(number, 2)
    memory_mib_min       = number
    allowed_types_arm64  = list(string)
    allowed_types_x86_64 = list(string)
  })
  default = null
}

variable "rightsize_schedule" {
  description = "systemd OnCalendar expression for the rightsize timer (gramps-rightsize-watchdog.timer), or null to disable and stop the timer. user-data applies it as a timer drop-in at boot, overriding the schedule baked into the AMI; an invalid expression or a pre-timer AMI keeps the baked-in default rather than failing the boot."
  type        = string
  nullable    = true
}

variable "rightsize_min_uptime_hours" {
  description = "Minimum instance uptime before the rightsize watchdog may force a replacement (its churn bound under aggressive schedules). Flows to the instance via the instance_runtime SSM parameter (ssm.tf), polled by the watchdog; one not yet polled since boot defaults to the same value (rightsize-watchdog.sh's own fallback)."
  type        = number
}

variable "cpu_credits" {
  description = "T-instance CPU credit mode. 'standard' caps CPU at baseline once earned credits are exhausted (no surplus charges). 'unlimited' allows sustained bursting at extra cost."
  type        = string
  default     = "standard"
  validation {
    condition     = contains(["standard", "unlimited"], var.cpu_credits)
    error_message = "cpu_credits must be 'standard' or 'unlimited'."
  }
}

variable "pathological_refresh_alarm_names" {
  description = "CloudWatch alarm names attached to instance_refresh's alarm_specification (asg.tf), so a refresh that never comes back gets reported Failed instead of Successful. Names, not ARNs: AlarmSpecification.Alarms is one of the few autoscaling fields that rejects an ARN outright (measured against the live API). Owned by the root module, not this one: monitoring already takes this module's asg_name as an input, so the alarm can't live in monitoring without a module cycle."
  type        = list(string)
}

variable "base_url" {
  description = "Public base URL of the site. Required by Gramps Web so email links resolve correctly."
  type        = string
}

variable "smtp" {
  description = "SES SMTP connection details, owned by module.email (see modules/email/outputs.tf)."
  type = object({
    host              = string
    username          = string
    from_address      = string
    password_ssm_path = string
    port              = number
    use_starttls      = bool
  })
}

variable "api" {
  description = "Gramps Web API (backend) config. See the api variable in variables.tf for the full field-by-field rationale; this module renders it into the gramps-env SSM parameter (see ssm.tf) and does no further validation of its own."
  type = object({
    tree                     = string
    tree_id                  = optional(string)
    registration             = string
    disable_telemetry        = bool
    pillow_max_image_pixels  = optional(number)
    max_thumbnail_file_bytes = optional(number)
    log_level                = optional(string)
    rate_limit_media_archive = optional(string)
    cors_origins             = optional(string)
    extra                    = map(string)
  })
}

variable "frontend" {
  description = "Gramps Web frontend runtime config (window.grampsjsConfig). See the frontend variable in variables.tf for the full field-by-field rationale."
  type = object({
    hide_dna_link        = bool
    login_redirect       = string
    map_base_style_light = string
    map_base_style_dark  = string
    map_ohm_style        = string
  })
}

variable "llm" {
  description = "AI chat assistant runtime config, resolved (region already picks the override vs the module's region). See the llm variable in variables.tf for the full field-by-field rationale; hourly_token_alarm is intentionally excluded here as it drives a root-level CloudWatch alarm, not app config."
  type = object({
    enabled            = bool
    model_id           = string
    region             = string
    max_requests       = number
    max_tokens         = number
    max_context_length = number
    system_prompt      = string
  })
}

variable "status_host_metrics" {
  description = "If true, the instance publishes disk/memory usage to the GrampsWeb CloudWatch namespace every 5 minutes (build/ami/health-watchdog.sh), and the instance role gets a scoped cloudwatch:PutMetricData grant. Read by the watchdog from the instance_runtime SSM parameter (ssm.tf), so flipping it costs no instance replacement -- only the IAM grant needs an apply. Consumed by the status page's host_metrics panel (status.host_metrics in the root variables); off by default, matching that panel's default."
  type        = bool
  default     = false
}

variable "status_volume_metrics" {
  description = "If true (and status_host_metrics is also true), the instance publishes DiskUsedBytes/DiskTotalBytes for both the data volume and root, each with a Mount=data|root dimension, instead of a single DiskUsedPercent for the data volume. Read by build/ami/health-watchdog.sh from the instance_runtime SSM parameter (ssm.tf); takes effect only once an instance is running an AMI built after this flag existed (the script is Packer-baked). Consumed by the status page's Storage panel (status.volume_metrics in the root variables); off by default, matching that panel's default."
  type        = bool
  default     = false
}

variable "instance_role_arn" {
  description = "Optional pre-existing IAM role ARN for the instance profile. When set, this module skips creating aws_iam_role.instance/aws_iam_instance_profile.instance and uses the passed role instead."
  type        = string
  default     = null
}
