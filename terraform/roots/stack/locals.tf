# For the derived-az default; unused when var.az is set.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  redirect_domains = toset([for k in keys(var.domains) : k if k != var.primary_domain])

  az = var.az != null ? var.az : data.aws_availability_zones.available.names[0]

  site_title = var.site_title != "" ? var.site_title : var.primary_domain

  # Addons baked into the image: the configured list, plus FilterRules when
  # the AI assistant is on (the chat warns when that plugin is absent, so it
  # is effectively a dependency of the feature, not a user choice).
  effective_addons = (
    var.llm.enabled
    ? distinct(concat(var.gramps_addons, ["FilterRules"]))
    : var.gramps_addons
  )

  # Region the celery workers (and so the AI chat model) run their AWS calls
  # from; primary unless the AI assistant is on AND var.llm overrides it
  # (quota workarounds). With the assistant off there is no reason for celery
  # to leave the primary region.
  llm_region = (
    var.llm.enabled && var.llm.region != ""
    ? var.llm.region
    : var.primary_region
  )

  # owner/repo for the CodeStarSourceConnection source action, derived from the
  # repo's HTTPS clone URL (single source of truth for the repo identity).
  source_repo = trimsuffix(replace(var.repo_url, "https://github.com/", ""), ".git")

  # Single source of truth for the managed CodeBuild image, fanned out to every
  # build project (ami-build, web-build, app-pipeline) so they never drift.
  codebuild_image = "aws/codebuild/standard:8.0"

  # Destination region for off-site backup copies. An explicit backup.region
  # wins; otherwise cross_region/cross_account default to us-east-2, and
  # local/disabled fall back to the primary region so the aws.backup provider
  # stays valid even though it creates nothing.
  #
  # Under cross_account this is also the region half of the destination vault
  # ARN the storage module constructs, so it must match the backup account's own
  # region variable -- a mismatch is a runtime copy-job failure, not a plan
  # error, because the vault lives in an account this stack cannot see.
  backup_region = (
    var.backup.region != "" ? var.backup.region :
    contains(["cross_region", "cross_account"], var.backup.mode) ? "us-east-2" :
    var.primary_region
  )

  # gramps-web-vault-reader is a fixed name in the backup account (see
  # terraform/roots/backup-account/iam.tf), so its ARN is constructed the same
  # way backup_copy_vault_arn's destination vault ARN is: a name contract, not
  # cross-account remote state. Empty except under cross_account, matching
  # when the status module actually needs to assume it.
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
