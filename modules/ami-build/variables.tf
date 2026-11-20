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
  description = "Region the AMIs are built in (the module's region). Injected into the build as REGION and used to fence the role's EC2 grants."
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

variable "ecr_repository_name" {
  description = "ECR repository name. The push of the gramps_web_version tag starts a build when auto_build is on."
  type        = string
}

variable "adopt_amis" {
  description = "Whether each build repoints the launch templates at its AMIs (false while ami_ids is pinned). Injected into the build as ADOPT_AMIS."
  type        = bool
}

variable "auto_build" {
  description = "Start a build weekly and on a push of the gramps_web_version tag to ECR."
  type        = bool
}

variable "max_age_days" {
  description = "A running AMI older than this makes the adopting build start an instance refresh (scripts/adopt-amis.sh). The age alarm fires at twice this."
  type        = number
}

variable "asg_name" {
  description = "Auto Scaling group whose launch templates are advanced."
  type        = string
}

variable "launch_template_ids" {
  description = "Launch template ID per architecture (keys arm64 and x86_64)."
  type        = map(string)
}

variable "instance_role_arn" {
  description = "Instance role the launch templates attach. The build passes it to EC2 when it repins the group."
  type        = string
}

variable "refresh_alarm_names" {
  description = "Alarms an instance refresh watches; the adopting build skips while one is in ALARM and passes them to the refresh it starts."
  type        = list(string)
}

variable "alarm_topic_arn" {
  description = "SNS topic the age and failed-build alarms notify."
  type        = string
}
