terraform {
  # Broad floor only; exact versions are pinned by the root module's lock file.
  required_version = ">= 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.45"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.7"
    }
  }
}
