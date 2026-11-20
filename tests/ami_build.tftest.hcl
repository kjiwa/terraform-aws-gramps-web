# Targets modules/ami-build directly with the inputs the root would pass.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/test" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_vpc" {
    defaults = { id = "vpc-0123456789abcdef0" }
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

  ecr_repository_name = "gramps-web"
  adopt_amis          = true
  auto_build          = true
  max_age_days        = 14
  asg_name            = "gramps-web"
  launch_template_ids = { arm64 = "lt-0aaaaaaaaaaaaaaaa", x86_64 = "lt-0bbbbbbbbbbbbbbbb" }
  instance_role_arn   = "arn:aws:iam::123456789012:role/gramps-web-instance"
  refresh_alarm_names = ["gramps-web-instance-refresh-pathological"]
  alarm_topic_arn     = "arn:aws:sns:us-east-1:123456789012:gramps-web-alerts"
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
        "ec2:DeleteVolume", "ec2:DeleteSnapshot", "ec2:DeregisterImage", "ec2:ModifyInstanceAttribute",
      ])) == 0
      if length(s.condition) == 0 || !anytrue([for c in s.condition : c.variable == "ec2:ResourceTag/Name"])
    ])
    error_message = "No statement without an ec2:ResourceTag/Name condition may hold DeleteVolume, DeleteSnapshot, DeregisterImage or ModifyInstanceAttribute."
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
      toset(s.actions) == toset(["ec2:DeleteVolume", "ec2:ModifyInstanceAttribute"]) &&
      anytrue([for c in s.condition : c.variable == "ec2:ResourceTag/Name" && toset(c.values) == toset(["packer-builder-gramps-web"])])
    ])
    error_message = "DeleteVolume and ModifyInstanceAttribute must be scoped to ec2:ResourceTag/Name = packer-builder-gramps-web."
  }
}

run "build_creates_no_security_group_and_scopes_image_attributes" {
  command = plan
  module {
    source = "./modules/ami-build"
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.ami_build.statement :
      length(setintersection(s.actions, [
        "ec2:CreateSecurityGroup", "ec2:AuthorizeSecurityGroupIngress", "ec2:DeleteSecurityGroup", "ec2:ModifyImageAttribute",
      ])) == 0
    ])
    error_message = "The build role must not create, open or delete security groups, and ModifyImageAttribute belongs to the scoped statement only."
  }
  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.ami_build_images.statement :
      s.sid == "PackerImageAttributes" && s.resources == toset(["arn:aws:ec2:us-east-1::image/*"])
    ])
    error_message = "ModifyImageAttribute must be scoped to images in the build region."
  }
  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.ami_build_images.statement :
      s.sid == "PackerStartSession" && anytrue([for c in s.condition : c.variable == "ssm:resourceTag/Name" && toset(c.values) == toset(["packer-builder-gramps-web"])])
    ])
    error_message = "ssm:StartSession must be limited to instances tagged as Packer builders."
  }
  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.ami_build_images.statement :
      s.sid == "PackerSessionDocument" && s.resources == toset(["arn:aws:ssm:us-east-1::document/AWS-StartPortForwardingSession"])
    ])
    error_message = "The session document must be AWS-StartPortForwardingSession, which Packer's session_manager communicator opens."
  }
  assert {
    condition     = aws_security_group.builder.name == "gramps-web-ami-builder" && aws_vpc_security_group_egress_rule.builder.ip_protocol == "-1"
    error_message = "The builder security group must exist with egress; no ingress rule is declared."
  }
}

run "adoption_grants_are_scoped_to_the_stack" {
  command = plan
  module {
    source = "./modules/ami-build"
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.ami_build_adopt.statement :
      s.sid == "AdoptTemplateVersions" &&
      s.actions == toset(["ec2:CreateLaunchTemplateVersion", "ec2:DeleteLaunchTemplateVersions"]) &&
      s.resources == toset(["arn:aws:ec2:us-east-1:123456789012:launch-template/lt-0aaaaaaaaaaaaaaaa", "arn:aws:ec2:us-east-1:123456789012:launch-template/lt-0bbbbbbbbbbbbbbbb"])
    ])
    error_message = "Template version writes must be limited to the two launch templates."
  }
  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.ami_build_adopt.statement :
      s.sid == "AdoptGroup" &&
      s.actions == toset(["autoscaling:UpdateAutoScalingGroup", "autoscaling:StartInstanceRefresh"]) &&
      s.resources == toset(["arn:aws:autoscaling:us-east-1:123456789012:autoScalingGroup:*:autoScalingGroupName/gramps-web"])
    ])
    error_message = "Repinning and refreshing must be limited to the gramps-web group."
  }
  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.ami_build_adopt.statement :
      s.sid == "PassInstanceRole" && s.resources == toset([var.instance_role_arn]) &&
      anytrue([for c in s.condition : c.variable == "iam:PassedToService" && toset(c.values) == toset(["ec2.amazonaws.com"])])
    ])
    error_message = "PassRole must name the instance role alone and only to EC2."
  }
}

run "automatic_builds_run_weekly_and_on_the_image_push" {
  command = plan
  module {
    source = "./modules/ami-build"
  }

  assert {
    condition     = aws_cloudwatch_event_rule.weekly[0].schedule_expression == "cron(0 6 ? * SUN *)"
    error_message = "The build must run weekly."
  }
  assert {
    condition     = jsondecode(aws_cloudwatch_event_rule.image_pushed[0].event_pattern).detail["image-tag"] == ["v1.0.0"] && jsondecode(aws_cloudwatch_event_rule.image_pushed[0].event_pattern).detail["repository-name"] == ["gramps-web"]
    error_message = "The push rule must match the app image tag for gramps_web_version in the stack's repository."
  }
}

run "a_pinned_stack_builds_only_by_hand_and_adopts_nothing" {
  command = plan
  module {
    source = "./modules/ami-build"
  }
  variables {
    adopt_amis = false
    auto_build = false
  }

  assert {
    condition     = length(aws_cloudwatch_event_rule.weekly) == 0 && length(aws_cloudwatch_event_rule.image_pushed) == 0
    error_message = "With auto_build off there must be no schedule or push rule."
  }
  assert {
    condition     = [for e in aws_codebuild_project.ami.environment[0].environment_variable : e.value if e.name == "ADOPT_AMIS"] == ["false"]
    error_message = "ADOPT_AMIS must be false while the AMIs are pinned."
  }
}

run "age_alarm_fires_at_twice_the_limit" {
  command = plan
  module {
    source = "./modules/ami-build"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.age.threshold == 28 && aws_cloudwatch_metric_alarm.age.metric_name == "AmiAgeDays" && aws_cloudwatch_metric_alarm.age.dimensions["AutoScalingGroupName"] == "gramps-web"
    error_message = "The age alarm must watch AmiAgeDays for the group at twice max_age_days."
  }
}

run "held_adoption_has_an_alarm" {
  command = plan
  module {
    source = "./modules/ami-build"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.held.metric_name == "AmiAdoptionHeld" && aws_cloudwatch_metric_alarm.held.threshold == 0 && aws_cloudwatch_metric_alarm.held.dimensions["AutoScalingGroupName"] == "gramps-web"
    error_message = "A build that holds a template must raise gramps-web-ami-held."
  }
}
