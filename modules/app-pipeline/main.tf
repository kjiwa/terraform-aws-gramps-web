# Build-and-deploy pipeline for Gramps Web. Source (this repo, via the shared
# CodeConnections GitHub app, manual-trigger only) -> Build (CodeBuild: build the
# image from source + addons, push a multi-arch index to ECR, emit the
# CodeDeploy bundle with the digest pinned) -> Deploy (the existing CodeDeploy
# app/group, which rolls the running instance and seeds every future spot
# replacement). The image version is a module variable and flows in as a build env
# var; running the pipeline builds and ships that version.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name       = "gramps-web"
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  # Everything build/app/build.sh consumes, all sourced from module variables: a
  # version bump is "change gramps.version, apply, run the pipeline".
  build_env = {
    ECR_REPO_URL       = var.ecr_repository_url
    GRAMPS_WEB_VERSION = var.gramps_web_version
    BASE_IMAGE         = var.gramps_base_image
    ADDONS_SOURCE_REPO = var.addons_source_repo
    ADDONS             = join(" ", var.gramps_addons)
    GRAMPS_WEB_REPO    = var.gramps_web_repo
    GRAMPS_WEB_REF     = var.gramps_web_ref
  }
}
