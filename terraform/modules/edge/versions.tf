terraform {
  # Broad floor only; exact versions are pinned by the root module's lock file.
  required_version = ">= 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.45"
      # us_east_1 exists because CloudFront only accepts ACM certificates from
      # us-east-1; only the ACM resources use it.
      configuration_aliases = [aws.us_east_1]
    }
  }
}
