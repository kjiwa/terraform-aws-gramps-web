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
