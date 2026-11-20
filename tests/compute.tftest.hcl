# The root module cannot assert on a child module's resources, so these runs
# target modules/compute directly with the inputs the root would pass.

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
  env                              = "prod"
  ami_ids                          = { arm64 = "ami-0aaaaaaaaaaaaaaaa", x86_64 = "ami-0bbbbbbbbbbbbbbbb" }
  active                           = true
  subnet_ids                       = ["subnet-0123456789abcdef0"]
  origin_sg_id                     = "sg-0123456789abcdef0"
  ebs_volume_id                    = "vol-0123456789abcdef0"
  ebs_volume_arn                   = "arn:aws:ec2:us-east-1:123456789012:volume/vol-0123456789abcdef0"
  media_bucket_name                = "gramps-web-media-123456789012"
  media_bucket_arn                 = "arn:aws:s3:::gramps-web-media-123456789012"
  pathological_refresh_alarm_names = ["gramps-web-instance-refresh-pathological"]
  base_url                         = "https://example.org"
  origin_certificate_arn           = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-1111-1111-1111-111111111111"
  rightsize_schedule               = null
  rightsize_min_uptime_hours       = 3
  smtp = {
    host              = "email-smtp.us-east-1.amazonaws.com"
    username          = "AKIATEST"
    from_address      = "gramps@example.org"
    password_ssm_path = "/gramps-web/prod/smtp-password"
    port              = 587
    use_starttls      = true
  }
  api = {
    tree              = "main"
    registration      = "open"
    disable_telemetry = false
    extra             = {}
  }
  frontend = {
    hide_dna_link        = false
    login_redirect       = ""
    map_base_style_light = ""
    map_base_style_dark  = ""
    map_ohm_style        = ""
  }
  llm = {
    enabled            = false
    model_id           = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
    region             = "us-east-1"
    max_requests       = 15
    max_tokens         = 200000
    max_context_length = 50000
    system_prompt      = ""
  }
}

run "spot_off_runs_on_demand" {
  command = plan
  module {
    source = "./modules/compute"
  }

  assert {
    condition     = aws_autoscaling_group.this.mixed_instances_policy[0].instances_distribution[0].on_demand_percentage_above_base_capacity == 100
    error_message = "Spot off must run 100 percent On-Demand."
  }
}

run "spot_on_runs_spot_only" {
  command = plan
  module {
    source = "./modules/compute"
  }
  variables {
    spot_enabled = true
  }

  assert {
    condition     = aws_autoscaling_group.this.mixed_instances_policy[0].instances_distribution[0].on_demand_percentage_above_base_capacity == 0
    error_message = "Spot on must run 0 percent On-Demand."
  }
}

run "derived_floor_is_4_gib_with_assistant_off" {
  command = plan
  module {
    source = "./modules/compute"
  }

  assert {
    condition     = length(aws_autoscaling_group.this.mixed_instances_policy[0].launch_template[0].override) == 2
    error_message = "Expected one launch template override per architecture."
  }

  assert {
    condition = alltrue([
      for o in aws_autoscaling_group.this.mixed_instances_policy[0].launch_template[0].override :
      o.instance_requirements[0].memory_mib[0].min == 4096
    ])
    error_message = "The derived memory floor must be 4096 MiB in every override, with the assistant off."
  }
}

run "active_false_sleeps_the_asg" {
  command = plan
  module {
    source = "./modules/compute"
  }
  variables {
    active = false
  }

  assert {
    condition     = aws_autoscaling_group.this.desired_capacity == 0 && aws_autoscaling_group.this.max_size == 0
    error_message = "active = false must hold the ASG at zero."
  }
}

run "active_true_runs_one_instance" {
  command = plan
  module {
    source = "./modules/compute"
  }

  assert {
    condition     = aws_autoscaling_group.this.desired_capacity == 1 && aws_autoscaling_group.this.max_size == 1
    error_message = "active = true must run one instance."
  }
}

run "eip_carries_the_project_tag_without_default_tags" {
  command = plan
  module {
    source = "./modules/compute"
  }

  assert {
    condition     = aws_eip.origin.tags["Project"] == "gramps-web"
    error_message = "The instance IAM policy conditions on aws:ResourceTag/Project, so the EIP must be tagged explicitly."
  }
}

run "instance_exports_only_the_origin_certificate" {
  command = plan
  module {
    source = "./modules/compute"
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.instance.statement :
      s.sid == "ACMOriginCertificate" &&
      s.actions == toset(["acm:ExportCertificate", "acm:DescribeCertificate"]) &&
      s.resources == toset([var.origin_certificate_arn])
    ])
    error_message = "The instance policy must grant acm:ExportCertificate and acm:DescribeCertificate on the origin certificate ARN alone."
  }
  assert {
    condition     = aws_ssm_parameter.origin_certificate_arn.name == "/gramps-web/prod/origin-certificate-arn" && aws_ssm_parameter.origin_certificate_arn.value == var.origin_certificate_arn
    error_message = "The origin certificate ARN must be published at /gramps-web/<env>/origin-certificate-arn."
  }
}

# Every service:operation scripts/keel/rightsize-check.sh calls through the aws CLI.
run "instance_policy_covers_the_rightsize_check" {
  command = plan
  module {
    source = "./modules/compute"
  }

  assert {
    condition = alltrue([
      for a in [
        "ec2:GetSpotPlacementScores",
        "ec2:DescribeSpotPriceHistory",
        "ec2:GetInstanceTypesFromInstanceRequirements",
        "autoscaling:DescribeAutoScalingGroups",
      ] :
      anytrue([
        for s in data.aws_iam_policy_document.instance.statement :
        s.sid == "RightsizePriceReads" && contains(s.actions, a)
      ])
    ])
    error_message = "The instance policy's RightsizePriceReads statement must grant every action the vendored rightsize check calls."
  }
}

run "image_pin_follows_only_the_operator_pin" {
  command = plan
  module {
    source = "./modules/compute"
  }

  assert {
    condition     = terraform_data.image_pin.input == null
    error_message = "With no ami_pin the pin resource holds null, so a new build never replaces a launch template."
  }
}

run "image_pin_carries_the_operator_pin" {
  command = plan
  module {
    source = "./modules/compute"
  }
  variables {
    ami_pin = { arm64 = "ami-0aaaaaaaaaaaaaaaa", x86_64 = "ami-0bbbbbbbbbbbbbbbb" }
  }

  assert {
    condition     = terraform_data.image_pin.input.arm64 == "ami-0aaaaaaaaaaaaaaaa"
    error_message = "A pin must reach terraform_data.image_pin, which replaces the templates when it changes."
  }
}

run "launch_templates_are_seeded_per_architecture" {
  command = plan
  module {
    source = "./modules/compute"
  }

  assert {
    condition     = aws_launch_template.this["arm64"].image_id == "ami-0aaaaaaaaaaaaaaaa" && aws_launch_template.this["x86_64"].image_id == "ami-0bbbbbbbbbbbbbbbb"
    error_message = "ami_ids must seed each launch template's image_id."
  }
}

run "instance_may_read_its_own_lifecycle_state" {
  command = plan
  module {
    source = "./modules/compute"
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.instance.statement :
      s.sid == "ReadOwnLifecycleState" && s.actions == toset(["autoscaling:DescribeAutoScalingInstances"])
    ])
    error_message = "gramps-spot-drain stop asks the ASG whether the instance is terminating; the instance policy must allow DescribeAutoScalingInstances."
  }
}

run "origin_secret_is_a_secure_string_under_the_env_path" {
  command = plan
  module {
    source = "./modules/compute"
  }

  assert {
    condition     = aws_ssm_parameter.origin_secret.name == "/gramps-web/prod/origin-secret" && aws_ssm_parameter.origin_secret.type == "SecureString"
    error_message = "The origin secret must be a SecureString at /gramps-web/<env>/origin-secret, under the path the instance role reads."
  }
  assert {
    condition     = random_password.origin_secret.length >= 32 && !random_password.origin_secret.special
    error_message = "The origin secret must be at least 32 characters with no special characters (it is written into an nginx map file)."
  }
}

run "origin_secret_starts_in_log_mode_with_no_extras" {
  command = plan
  module {
    source = "./modules/compute"
  }

  assert {
    condition     = aws_ssm_parameter.origin_secret_mode.name == "/gramps-web/prod/origin-secret-mode" && aws_ssm_parameter.origin_secret_mode.value == "log"
    error_message = "The proxy must only log a missing or wrong origin secret unless origin_secret_enforce is true."
  }
  assert {
    condition     = length(aws_ssm_parameter.origin_secret_extra) == 0
    error_message = "No extra accepted secret parameter without origin_secret_extra."
  }
}

run "origin_secret_enforce_and_extras_reach_ssm" {
  command = plan
  module {
    source = "./modules/compute"
  }
  variables {
    origin_secret_enforce = true
    origin_secret         = "NEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEW"
    origin_secret_extra   = ["OLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLD", "TWOTWOTWOTWOTWOTWOTWOTWOTWOTWOTWOTWOTWOTWO"]
  }

  assert {
    condition     = aws_ssm_parameter.origin_secret_mode.value == "enforce"
    error_message = "origin_secret_enforce must publish mode enforce."
  }
  assert {
    condition     = aws_ssm_parameter.origin_secret.value == "NEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEW"
    error_message = "An origin_secret override must replace the generated secret."
  }
  assert {
    condition     = aws_ssm_parameter.origin_secret_extra[0].type == "SecureString" && aws_ssm_parameter.origin_secret_extra[0].name == "/gramps-web/prod/origin-secret-extra"
    error_message = "Extra accepted secrets must be a SecureString beside the others."
  }
}

run "origin_secret_values_must_fit_the_proxy_hash_bucket" {
  command = plan
  module {
    source = "./modules/compute"
  }
  variables {
    origin_secret = "AbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAbAb"
  }
  expect_failures = [var.origin_secret]
}

run "origin_secret_values_must_be_map_safe" {
  command = plan
  module {
    source = "./modules/compute"
  }
  variables {
    origin_secret_extra = ["has space\"quote"]
  }
  expect_failures = [var.origin_secret_extra]
}
