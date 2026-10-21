variable "repo_url" {
  description = "HTTPS clone URL of the infra repo CodeBuild pulls (must contain build/ami/, which holds the buildspec, the build script, and the packer files, plus scripts/ for the shared helpers). e.g. https://github.com/owner/repo.git"
  type        = string
}

variable "source_branch" {
  description = "Branch CodeBuild builds from."
  type        = string
  default     = "main"
}

variable "region" {
  description = "Region the AMIs are built in (the stack's primary_region). Injected into the build as REGION and used to fence the role's EC2 grants."
  type        = string
}

variable "connection_arn" {
  description = "CodeConnections (GitHub) connection ARN, shared with the other build projects and created at the env level."
  type        = string
}

variable "codebuild_image" {
  description = "Managed CodeBuild image for the build project. Shared across the stack's build projects so the version stays in lockstep."
  type        = string
}

variable "ecr_repository_url" {
  description = "ECR repository URL the build's grampsweb pull is pinned to (build/ami/install.sh's pull_images). Injected into the build as ECR_REPO_URL."
  type        = string
}

variable "ecr_repository_arn" {
  description = "ECR repository ARN, for scoping the builder role's ECR read grant to just this repository."
  type        = string
}

variable "gramps_web_version" {
  description = "Upstream grampsweb image tag to pre-pull into the AMI. Injected into the build as GRAMPS_WEB_VERSION; a tag not yet pushed to ECR is a non-fatal miss (the deploy pulls it the ordinary way instead)."
  type        = string
}
