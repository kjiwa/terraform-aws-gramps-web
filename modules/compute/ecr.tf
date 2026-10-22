# Private registry for the Gramps Web image built by the app pipeline. This
# replaces the runtime GHCR dependency: instances pull the digest-pinned image
# from here (in-region, dual-stack, layers served from S3), so the IPv4-only
# GHCR pull leaves the spot-launch path entirely. The app-pipeline module pushes
# a multi-arch index tagged with gramps_web_version; instances pull by the index
# digest baked into the CodeDeploy revision.
resource "aws_ecr_repository" "gramps" {
  name = "gramps-web"

  # The same version tag is re-pushed when only the addon set changes, so the
  # tag must be mutable. Pulls are pinned by digest regardless, so mutability
  # never affects what a running instance fetches.
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "gramps-web"
  }
}

# Keep storage bounded: drop the dangling manifests buildx leaves behind, and
# cap tagged history. The running version is pinned by digest in the CodeDeploy
# revision (not by tag), so expiring old tags never breaks a launch.
resource "aws_ecr_lifecycle_policy" "gramps" {
  repository = aws_ecr_repository.gramps.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last 40 tagged manifests (tagStatus=any counts every index/platform/attestation manifest per push, not app versions)"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 40
        }
        action = { type = "expire" }
      },
    ]
  })
}
