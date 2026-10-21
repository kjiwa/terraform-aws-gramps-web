variable "connection_arn" {
  description = "CodeConnections (GitHub) connection ARN, shared with the other build projects. Approve once in the console before the first run."
  type        = string
}

variable "repo_full_name" {
  description = "GitHub owner/repo the pipeline builds from, e.g. owner/repo."
  type        = string
}

variable "source_branch" {
  description = "Branch the pipeline builds from."
  type        = string
  default     = "main"
}

variable "gramps_web_version" {
  description = "Upstream grampsweb image tag to build from (e.g. 26.10.2). Injected into the build; the Gramps-core version and addon branch are derived from it at build time."
  type        = string
}

variable "gramps_base_image" {
  description = "Upstream grampsweb image the app image derives FROM; tagged with gramps_web_version at build time."
  type        = string
}

variable "gramps_addons" {
  description = "Addon directory names (root of addons-source) to bake into the image. Empty builds the plain upstream image."
  type        = list(string)
}

variable "gramps_web_repo" {
  description = "Optional gramps-web (frontend) repo whose built dist/ overlays the upstream image's frontend. Empty ships the upstream frontend."
  type        = string
}

variable "gramps_web_ref" {
  description = "Git ref of gramps_web_repo to build. Required when the repo is set."
  type        = string
}

variable "addons_source_repo" {
  description = "Git URL of the Gramps addons-source repo."
  type        = string
}

variable "instance_role_name" {
  description = "EC2 instance role name. Granted read on this pipeline's artifact bucket so the CodeDeploy agent can fetch deployment bundles."
  type        = string
}

variable "ecr_repository_url" {
  description = "ECR repository URL to push the built image to."
  type        = string
}

variable "ecr_repository_arn" {
  description = "ECR repository ARN. Scopes the build role's push permissions."
  type        = string
}

variable "codedeploy_app_name" {
  description = "CodeDeploy application the Deploy stage targets."
  type        = string
}

variable "codedeploy_deployment_group_name" {
  description = "CodeDeploy deployment group the Deploy stage targets."
  type        = string
}

variable "codebuild_image" {
  description = "Managed CodeBuild image for the build project. Shared across the stack's build projects so the version stays in lockstep."
  type        = string
}
