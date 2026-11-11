# Targets modules/ami-build directly with the inputs the root would pass.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/test" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  repo_url           = "https://github.com/example/gramps-web"
  region             = "us-east-1"
  connection_arn     = "arn:aws:codeconnections:us-east-1:123456789012:connection/00000000-0000-0000-0000-000000000000"
  codebuild_image    = "aws/codebuild/amazonlinux-aarch64-standard:3.0"
  ecr_repository_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/gramps-web"
  ecr_repository_arn = "arn:aws:ecr:us-east-1:123456789012:repository/gramps-web"
  gramps_web_version = "v1.0.0"
}

run "build_role_deletes_only_what_it_tagged" {
  command = plan
  module {
    source = "./modules/ami-build"
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.ami_build.statement :
      length(setintersection(s.actions, [
        "ec2:DeleteVolume", "ec2:DeleteSnapshot", "ec2:DeleteSecurityGroup", "ec2:DeregisterImage", "ec2:ModifyInstanceAttribute",
      ])) == 0
      if s.sid == "PackerBuild"
    ])
    error_message = "The PackerBuild statement must not hold DeleteVolume, DeleteSnapshot, DeleteSecurityGroup, DeregisterImage or ModifyInstanceAttribute."
  }
  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.ami_build.statement :
      toset(s.actions) == toset(["ec2:DeleteSnapshot", "ec2:DeregisterImage"]) &&
      anytrue([for c in s.condition : c.variable == "ec2:ResourceTag/Name" && toset(c.values) == toset(["gramps-web-base"])])
    ])
    error_message = "DeleteSnapshot and DeregisterImage must be scoped to ec2:ResourceTag/Name = gramps-web-base."
  }
  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.ami_build.statement :
      toset(s.actions) == toset(["ec2:DeleteVolume", "ec2:DeleteSecurityGroup", "ec2:ModifyInstanceAttribute"]) &&
      anytrue([for c in s.condition : c.variable == "ec2:ResourceTag/Name" && toset(c.values) == toset(["packer-builder-gramps-web"])])
    ])
    error_message = "DeleteVolume, DeleteSecurityGroup and ModifyInstanceAttribute must be scoped to ec2:ResourceTag/Name = packer-builder-gramps-web."
  }
}
