terraform {
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.45"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    # Not used directly by this root; declared so Dependabot (scoped to
    # terraform/roots/*) sees it and keeps the lock file's archive entry
    # current. Actual use is in terraform/modules/{status,monitoring}.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.8"
    }
  }
}

provider "aws" {
  region = var.primary_region

  # Refuse to plan/apply against any other account: with one account per env,
  # this turns "wrong AWS_PROFILE" into an immediate error instead of a
  # cross-env deployment.
  allowed_account_ids = var.account_id != "" ? [var.account_id] : null

  default_tags {
    tags = {
      Project   = "gramps-web"
      Env       = var.env
      ManagedBy = "terraform"
    }
  }
}

# CloudFront only accepts ACM certificates issued in us-east-1, regardless of
# where the rest of the stack runs; the edge module pins its certificates to
# this alias so setting primary_region elsewhere cannot silently break them.
# The finops module (Budgets + Cost Explorer, global services reached via the
# us-east-1 endpoint) also runs under this alias, as does the dns module's
# DNSSEC KSK key (Route 53 DNSSEC requires the key in us-east-1 regardless of
# primary_region).
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  allowed_account_ids = var.account_id != "" ? [var.account_id] : null

  default_tags {
    tags = {
      Project   = "gramps-web"
      Env       = var.env
      ManagedBy = "terraform"
    }
  }
}

# Destination region for off-site backups (the replica backup vault + its key,
# created only when backup.mode = cross_region). region resolves to the primary
# region when backups are local/disabled so the provider is always well-formed;
# the destination resources simply have count 0 then.
#
# Still this account, note: cross_account copies into a vault another account
# owns and terraform/roots/backup-account manages, so this stack never needs
# credentials for the backup account -- it only names the destination vault's
# ARN. That is deliberate. A stack that could write to the backup account would
# undo the isolation the backup account exists to provide.
provider "aws" {
  alias  = "backup"
  region = local.backup_region

  allowed_account_ids = var.account_id != "" ? [var.account_id] : null

  default_tags {
    tags = {
      Project   = "gramps-web"
      Env       = var.env
      ManagedBy = "terraform"
    }
  }
}

# The region Bedrock is invoked in (local.llm_region -- primary unless llm.region
# overrides it). AWS/Bedrock CloudWatch metrics are published in the invocation
# region, so the token-cost alarm must be created here, not under the default or
# us_east_1 providers. Resolves to the primary region when the assistant is off,
# keeping the provider valid; the alarm is count 0 then.
provider "aws" {
  alias  = "bedrock"
  region = local.llm_region

  allowed_account_ids = var.account_id != "" ? [var.account_id] : null

  default_tags {
    tags = {
      Project   = "gramps-web"
      Env       = var.env
      ManagedBy = "terraform"
    }
  }
}
