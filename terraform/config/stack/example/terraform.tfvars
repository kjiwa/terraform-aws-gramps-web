# Minimal deployment config. To create an environment:
#   cp -r terraform/config/stack/example terraform/config/stack/<env>
# fill in this file and backend.hcl, then
#   scripts/tf.sh <env> init && scripts/tf.sh <env> apply
# README.md ("Deploying to your own AWS account") is the full walkthrough.

# ------------------------------------------------------------------ REQUIRED

# Must match this directory's name. One AWS account per environment.
env = "example"

# Apex domain(s) served. primary_domain is the canonical one (must be a key
# of domains); the rest (and every www.) 301 to it. Add dnssec = true per
# domain to enable DNSSEC (a KMS KSK, ~$1/mo per domain).
primary_domain = "example.org"

domains = {
  "example.org" = {}
}

# Receives site DOWN/RECOVERED emails. Confirm the SNS subscription email
# after the first apply.
alert_email = "you@example.org"

# Your fork of this repo; the builds pull buildspecs and scripts/ from it.
repo_url = "https://github.com/you/your-fork"

# Upstream grampsweb release the app pipeline builds from. Bump, apply, then
# scripts/deploy.sh gramps.
gramps_web_version = "26.10.2"

# Strongly recommended: the AWS account this env deploys to. The provider
# refuses any other account, so a wrong AWS_PROFILE fails fast. Empty ("")
# disables the guard.
account_id = "000000000000"

# Base AMI per architecture: the newest gramps-web-base AMIs from the first
# Packer build (build/ami/build.sh prints them when it finishes). Rebuilds
# roll out nothing until these are bumped and applied.
ami_ids = {
  arm64  = "ami-00000000000000000"
  x86_64 = "ami-00000000000000000"
}

# ------------------------------------------------------------------ OPTIONAL
# Everything below has a working default in terraform/roots/stack/variables.tf
# (where each knob is documented); shown here with its default value.

# primary_region = "us-east-1"   # workload region
# az             = null          # null = first available AZ; pin to choose
# site_title     = ""            # error-page title; "" = the primary domain
# active         = true          # false = sleep: zero instances, data kept
# spot_enabled   = false         # true = Spot only, ~1/3 the price, ~5 min
#                                # outage per reclaim
# spot_allocation_strategy = "price-capacity-optimized"  # or "lowest-price"

# AI chat assistant (Bedrock). Enabling is the only required change; model,
# invoke region, and usage caps are tunable (defaults in variables.tf).
# Instance sizing and the Bedrock IAM grant are derived from this. Needs
# one-time Anthropic model access enabled in the Bedrock console.
# llm = { enabled = true }

# Authenticated operational status page at /_status: reliability, incidents,
# host/image/deployment/storage, DR posture (local + off-site backups).
# Gated on the caller's own Gramps Web role; min_role
# (guest/member/contributor/editor/owner/admin/nobody) picks the floor,
# default owner. host_metrics and cost are separate, money-costing
# sub-toggles that default off; volume_metrics (also money-costing, off by
# default) requires host_metrics and switches the Storage panel's disk
# reading to exact bytes. Full detail: the status variable in
# terraform/roots/stack/variables.tf.
# status = { enabled = true, min_role = "owner" }

# gramps_addons      = []      # addon dirs from addons-source, baked in
# media_bucket_name  = ""      # "" derives gramps-web-media-<account-id>
# dmarc_rua          = ""      # mailto: URI for DMARC aggregate reports
# cpu_credits        = "standard"              # or "unlimited"
# rightsize_schedule = null                    # a daily hour (e.g. "*-*-* 09:00:00 UTC") turns on
#                                              # Spot scale-back; needs lowest-price
# source_branch      = "main"                  # branch the builds pull

# Gramps Web's own settings. frontend is the browser runtime config
# (window.grampsjsConfig); an empty string field falls back to upstream's own
# default and is omitted from the file entirely.
# frontend = {
#   hide_dna_link        = false  # false shows the DNA-match link in the UI
#   login_redirect       = ""     # where signed-out visitors land instead
#   map_base_style_light = ""     # MapLibre style URL, light theme
#   map_base_style_dark  = ""     # MapLibre style URL, dark theme
#   map_ohm_style        = ""     # MapLibre style URL, OpenHistoricalMap overlay
# }

# api is the backend env. registration picks the sign-up mode; tree_id is
# required if tree is ever changed from "main". log_level,
# rate_limit_media_archive, and cors_origins are unset (null) by default,
# leaving upstream's own defaults. extra passes through any other non-secret
# Gramps Web API setting upstream documents, as bare upstream keys (no
# GRAMPSWEB_ prefix) -- the settings this stack derives are denylisted there,
# each with its reason, in terraform/roots/stack/variables.tf.
# api = {
#   tree                     = "main"  # upstream tree directory name
#   tree_id                  = null    # required when tree != "main"
#   registration             = "open"  # open, unlisted, or closed -- see variables.tf
#   disable_telemetry        = false   # send Gramps Web's upstream telemetry
#   pillow_max_image_pixels  = null    # PILLOW_MAX_IMAGE_PIXELS
#   max_thumbnail_file_bytes = null    # MAX_THUMBNAIL_FILE_BYTES
#   log_level                = null    # DEBUG, INFO, WARNING, ERROR, or CRITICAL
#   rate_limit_media_archive = null    # e.g. "10 per day"; upstream default is "1 per day"
#   cors_origins             = null    # e.g. "https://example.org"
#   extra                    = {}      # e.g. CELERY_CONFIG__broker_url = "..."
# }

# monthly_budget_usd = 50      # FinOps guardrail: emails alert_email at 80%
#                              # actual / 100% forecasted monthly spend.

# Off-site backups of the EBS data volume + S3 media, via one AWS Backup plan.
# The default (mode = "local") keeps daily recovery points in this account and
# region. Opt into DR:
#   backup = { mode = "cross_region", region = "us-east-2" }   # region failover
#   backup = { mode = "disabled" }                             # no backups
# cross_account copies into a vault another org account owns -- the only copy
# that survives losing this account. It is a gated migration, not a tfvars flip
# (docs/cross-account-backup.md):
#   backup = { mode = "cross_account", account_id = "...", region = "us-east-2" }
# retention_days / remote_retention_days set how long recovery points and their
# copies live; schedule sets when the plan runs. Defaults and details: the
# backup variable in terraform/roots/stack/variables.tf.
# backup = { mode = "local", schedule = "cron(0 3 * * ? *)" }

# Disaster rebuild only: create the data volume from an EC2 snapshot ID
# (scripts/restore.sh offsite, then a snapshot of the result) instead of
# empty. First apply only -- see docs/restore.md.
# data_volume_snapshot_id = "snap-0123456789abcdef0"

# Size of the EBS data volume in GiB (gp3). Raising it is in place; lowering
# it is scripts/azmove.sh shrink.
# data_volume_gb = 5
