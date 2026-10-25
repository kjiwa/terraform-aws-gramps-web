variable "repo_url" {
  description = "HTTPS clone URL of the infra repo CodeBuild pulls (must contain build/web/, which holds the buildspec, the build script, and the frontend source). e.g. https://github.com/owner/repo.git"
  type        = string
}

variable "source_branch" {
  description = "Branch CodeBuild builds from."
  type        = string
  default     = "main"
}

variable "site_title" {
  description = "Human-facing site name, baked into the static error pages at build time as SITE_TITLE (build/web/src/error/pages.ts)."
  type        = string
}

variable "status_public_page" {
  description = "Whether /_status/public is served; baked into the static error pages at build time as STATUS_PUBLIC_PAGE, which adds their measured outage line and status link."
  type        = bool
}

variable "errors_bucket_name" {
  description = "Name of the error-pages S3 bucket to publish to (module.edge's errors_bucket_name output)."
  type        = string
}

variable "errors_bucket_arn" {
  description = "ARN of the error-pages S3 bucket."
  type        = string
}

variable "distribution_id" {
  description = "Primary CloudFront distribution ID to invalidate after publish."
  type        = string
}

variable "connection_arn" {
  description = "CodeConnections (GitHub) connection ARN, shared with the app and AMI build projects."
  type        = string
}

variable "codebuild_image" {
  description = "Managed CodeBuild image for the build project. Shared across the stack's build projects so the version stays in lockstep."
  type        = string
}
