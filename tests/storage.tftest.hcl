# Targets modules/storage directly with the inputs the root would pass.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/test" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1", name = "us-east-1" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  az            = "us-east-1a"
  backup_region = "us-east-1"
  backup = {
    mode                  = "local"
    region                = ""
    account_id            = ""
    retention_days        = 35
    remote_retention_days = 35
    dest_vault_name       = ""
    schedule              = "cron(0 5 * * ? *)"
  }
}

run "local_backup_names_the_live_vault_and_selects_volume_and_bucket" {
  command = plan
  module {
    source = "./modules/storage"
  }

  assert {
    condition     = module.data_volume.vault_name == "gramps-web-backup"
    error_message = "The data-volume module must reproduce the live vault name."
  }
  assert {
    condition     = output.backup_vault_name == "gramps-web-backup"
    error_message = "modules/storage must keep exporting backup_vault_name."
  }
  assert {
    condition     = output.backup_resource_count == 2
    error_message = "The selection covers the data volume and the media bucket."
  }
  assert {
    condition     = output.backup_remote_retention_days == 35 && output.backup_copy_vault_arn == null && output.ebs_kms_key_arn == null
    error_message = "Local mode has no copy vault and no data-volume key."
  }
}

run "disabled_backup_has_no_vault" {
  command = plan
  module {
    source = "./modules/storage"
  }
  variables {
    backup = {
      mode                  = "disabled"
      region                = ""
      account_id            = ""
      retention_days        = 35
      remote_retention_days = 0
      dest_vault_name       = ""
      schedule              = "cron(0 5 * * ? *)"
    }
  }

  assert {
    condition     = output.backup_vault_name == null
    error_message = "Disabled backups create no vault."
  }
}

run "cross_account_constructs_the_destination_vault_arn" {
  command = plan
  module {
    source = "./modules/storage"
  }
  variables {
    backup_region = "us-east-2"
    backup = {
      mode                  = "cross_account"
      region                = "us-east-2"
      account_id            = "000000000000"
      retention_days        = 35
      remote_retention_days = 90
      dest_vault_name       = "gramps-web-backup-replica"
      schedule              = "cron(0 5 * * ? *)"
    }
  }

  assert {
    condition     = output.backup_copy_vault_arn == "arn:aws:backup:us-east-2:000000000000:backup-vault:gramps-web-backup-replica"
    error_message = "The destination vault ARN is account + region + name."
  }
  assert {
    condition     = output.backup_remote_retention_days == 90
    error_message = "The remote retention must come through unchanged."
  }
}
