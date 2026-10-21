# Base AMIs built by Packer (build/ami/gramps-ami.pkr.hcl, normally via the
# gramps-web-ami CodeBuild project), pinned per architecture in tfvars. A
# rebuild changes nothing until ami_ids is bumped: AMI rollout is a deliberate
# commit (bump, apply -> new launch template version -> ASG instance refresh)
# and rollback is reverting it. Candidates, newest first:
#   aws ec2 describe-images --owners self \
#     --filters Name=tag:Name,Values=gramps-web-base Name=state,Values=available \
#     --query 'reverse(sort_by(Images,&CreationDate))[].[Architecture,ImageId,CreationDate]' \
#     --output text
locals {
  # Architectures the ASG provisions across. Keys flow through to the launch
  # templates (one per arch) and the mixed-instances overrides.
  architectures = toset(["arm64", "x86_64"])
}

resource "aws_launch_template" "this" {
  for_each = local.architectures

  # name_prefix is ForceNew and kept arch-independent. Tell the two apart by
  # the Architecture column or image_id in the console.
  name_prefix   = "gramps-web-"
  image_id      = var.ami_ids[each.key]
  ebs_optimized = true

  iam_instance_profile {
    arn = aws_iam_instance_profile.instance.arn
  }

  vpc_security_group_ids = [var.origin_sg_id]

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    region                 = local.region
    eip_allocation_id      = aws_eip.origin.id
    ebs_volume_id          = var.ebs_volume_id
    ssm_runtime_param      = aws_ssm_parameter.gramps_env.name
    ssm_flask_secret_path  = aws_ssm_parameter.flask_secret.name
    ssm_smtp_password_path = var.smtp.password_ssm_path
    # Region for the celery workers' AWS_DEFAULT_REGION (docker-compose.yml);
    # not a GRAMPSWEB_* app setting, so it does not travel through the
    # gramps-env parameter -- it reaches the instance via instance.env instead,
    # same as REGION above.
    celery_region = var.llm.region
    # Applied as a systemd timer drop-in at boot; "" disables the timer. See
    # configure_rightsize_timer.
    rightsize_schedule = var.rightsize_schedule == null ? "" : var.rightsize_schedule
    # Names, not values: STATUS_* and RIGHTSIZE_MIN_UPTIME_HOURS live in the
    # instance_runtime parameter instead (ssm.tf), polled by the watchdogs so
    # changing one of them never renders a new launch template.
    ssm_instance_runtime_param = aws_ssm_parameter.instance_runtime.name
    ssm_frontend_config_param  = aws_ssm_parameter.frontend_config.name
    # Cause-attribution markers (watchdog_markers.tf); each watchdog writes
    # its own just before acting, for the availability Lambda to read back.
    last_rightsize_param       = aws_ssm_parameter.last_rightsize.name
    last_health_watchdog_param = aws_ssm_parameter.last_health_watchdog.name
    # Not a reference to modules/edge's output (that would be a dependency
    # cycle; see edge/ssm.tf) -- just the same deterministic path that module
    # publishes the distribution ID under, built from var.env like every
    # other /gramps-web/<env>/* parameter this module already knows the name
    # of. validate_service.sh resolves it to the real ID at deploy time.
    cloudfront_distribution_id_param = "/gramps-web/${var.env}/cloudfront-distribution-id"
  }))

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    # 2, not the IMDS default of 1: the app containers reach IMDS across the
    # Docker bridge, which is one extra hop. At 1, every container-side AWS
    # SDK credential fetch would fail.
    http_put_response_hop_limit = 2
  }

  monitoring {
    enabled = false
  }

  credit_specification {
    cpu_credits = var.cpu_credits
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "gramps-web-root"
    }
  }

  lifecycle {
    create_before_destroy = true

    # aws_ssm_parameter.gramps_env and aws_ssm_parameter.frontend_config are
    # siblings under /gramps-web/${var.env}/ by convention -- catch a rename
    # that splits them at plan time rather than as an operational surprise.
    precondition {
      condition     = dirname(aws_ssm_parameter.gramps_env.name) == dirname(aws_ssm_parameter.frontend_config.name)
      error_message = "aws_ssm_parameter.gramps_env and aws_ssm_parameter.frontend_config must share a path prefix."
    }
  }
}
