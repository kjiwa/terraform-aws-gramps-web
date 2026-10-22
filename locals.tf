data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

# For the derived-az default; unused when var.az is set.
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_route53_zone" "this" {
  for_each     = toset(local.domains)
  name         = each.key
  private_zone = false
}

data "aws_ami" "base" {
  for_each    = var.ami_ids == null ? toset(["arm64", "x86_64"]) : toset([])
  owners      = ["self"]
  most_recent = true

  filter {
    name   = "tag:Name"
    values = ["gramps-web-base"]
  }
  filter {
    name   = "architecture"
    values = [each.key]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  region  = data.aws_region.current.region
  domains = var.domains != null ? var.domains : [var.primary_domain]

  redirect_domains = toset([for d in local.domains : d if d != var.primary_domain])

  zone_ids = { for d, z in data.aws_route53_zone.this : d => z.zone_id }

  ami_ids = var.ami_ids != null ? var.ami_ids : { for a, ami in data.aws_ami.base : a => ami.id }

  az = var.az != null ? var.az : data.aws_availability_zones.available.names[0]

  site_title = var.site_title != "" ? var.site_title : var.primary_domain

  # Addons baked into the image: the configured list, plus FilterRules when
  # the AI assistant is on (the chat warns when that plugin is absent, so it
  # is effectively a dependency of the feature, not a user choice).
  effective_addons = (
    var.llm.enabled
    ? distinct(concat(var.gramps.addons, ["FilterRules"]))
    : var.gramps.addons
  )

  # Region the celery workers (and so the AI chat model) call AWS from: the
  # module's own region unless the assistant is on and llm.region overrides it.
  llm_region = (
    var.llm.enabled && var.llm.region != ""
    ? var.llm.region
    : local.region
  )

  # owner/repo for the CodeStarSourceConnection source action, derived from the
  # repo's HTTPS clone URL (single source of truth for the repo identity).
  source_repo = trimsuffix(replace(var.repo_url, "https://github.com/", ""), ".git")

  # Single source of truth for the managed CodeBuild image, fanned out to every
  # build project (ami-build, web-build, app-pipeline) so they never drift.
  codebuild_image = "aws/codebuild/standard:8.0"

  # Destination region for off-site backup copies. An explicit backup.region
  # wins; otherwise cross_region/cross_account default to us-east-2, and
  # local/disabled use the module's region.
  #
  # Under cross_account this is also the region half of the destination vault
  # ARN the storage module constructs, so it must match the destination
  # account's vault region -- a mismatch is a runtime copy-job failure, not a
  # plan error, because the vault lives in an account this module cannot see.
  backup_region = (
    var.backup.region != "" ? var.backup.region :
    contains(["cross_region", "cross_account"], var.backup.mode) ? "us-east-2" :
    local.region
  )

  # gramps-web-vault-reader is a fixed name in the backup account (keel's
  # backup-vault-account module), so its ARN is constructed the same way the
  # destination vault ARN is: a name contract, not cross-account remote state.
  # Empty except under cross_account, matching when the status module actually
  # needs to assume it.
  backup_dest_reader_role_arn = (
    var.backup.mode == "cross_account"
    ? "arn:aws:iam::${var.backup.account_id}:role/gramps-web-vault-reader"
    : ""
  )

  # Panels the static status shell hides before its first data fetch
  # resolves (see modules/edge/status_assets.tf).
  status_disabled_panels = compact([
    module.storage.backup_vault_name == null ? "backups" : "",
    var.llm.enabled ? "" : "assistant",
    var.status.cost ? "" : "cost",
    var.status.host_metrics ? "" : "host_metrics",
  ])
}
