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

run "data_volume_carries_the_project_tag_without_default_tags" {
  command = plan
  module {
    source = "./modules/storage"
  }

  assert {
    condition     = aws_ebs_volume.this.tags["Project"] == "gramps-web"
    error_message = "The instance IAM policy conditions on aws:ResourceTag/Project, so the volume must be tagged explicitly."
  }
}
