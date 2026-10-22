terraform {
  # Broad floor only; exact versions are pinned by the root module's lock file.
  required_version = ">= 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.45"
      # aws.backup is the destination-region provider for off-site copies (the
      # replica backup vault + its KMS key). Configured by the root stack; the
      # module only creates resources under it when backup.mode = cross_region.
      # cross_account copies into a vault another account owns, so it needs no
      # provider here -- only the vault's ARN, which backup.tf constructs.
      configuration_aliases = [aws.backup]
    }
  }
}
