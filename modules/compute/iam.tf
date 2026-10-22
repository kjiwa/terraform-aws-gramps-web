data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  # Regions the AI chat model may be invoked from: the deployment region plus
  # the (possibly identical) override; toset dedupes.
  llm_invoke_regions = toset([local.region, var.llm.region])
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "gramps-web-instance"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = {
    Name = "gramps-web-instance"
  }
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "instance" {
  # EBS: read-only discovery.
  statement {
    sid       = "EBSDescribe"
    effect    = "Allow"
    actions   = ["ec2:DescribeVolumes"]
    resources = ["*"]
  }

  # EBS: attach/detach scoped to the specific volume; instance side
  # constrained by tag. Detach lets spot-drain.sh and rightsize-watchdog.sh
  # release the volume ahead of replacement (build/ami/gramps-runtime.sh's
  # detach_data_volume) so the ASG's replacement can attach it immediately.
  statement {
    sid     = "EBSAttachDetach"
    effect  = "Allow"
    actions = ["ec2:AttachVolume", "ec2:DetachVolume"]
    resources = [
      var.ebs_volume_arn,
      "arn:aws:ec2:${local.region}:${local.account_id}:instance/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["gramps-web"]
    }
  }

  # EIP: associate; instance side constrained by tag, EIP scoped to allocation.
  statement {
    sid     = "EIPAssociate"
    effect  = "Allow"
    actions = ["ec2:AssociateAddress"]
    resources = [
      aws_eip.origin.arn,
      "arn:aws:ec2:${local.region}:${local.account_id}:instance/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["gramps-web"]
    }
  }

  # S3: media bucket.
  statement {
    sid    = "S3MediaObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${var.media_bucket_arn}/*"]
  }

  statement {
    sid       = "S3MediaBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.media_bucket_arn]
  }

  # KMS: use the data volume's CMK, so user-data can attach it at boot.
  #
  # Only exists when the volume HAS a CMK (backup.mode = cross_account; see
  # modules/storage/main.tf for why that is the only mode that needs one). Null
  # elsewhere, where the volume is on the AWS-managed aws/ebs key, whose policy
  # grants the account's principals implicitly -- which is exactly why this
  # statement is easy to forget: the aws/ebs volume attaches with no KMS grant
  # at all, so nothing here looks missing until the day the volume is re-keyed
  # and every instance fails to boot with CustomerKeyHasBeenRevoked. AttachVolume
  # passing IAM is not enough; EC2 still has to reach the key.
  dynamic "statement" {
    for_each = var.ebs_kms_key_arn != null ? [1] : []
    content {
      sid    = "KMSDataVolume"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:GenerateDataKeyWithoutPlaintext",
        "kms:ReEncryptFrom",
        "kms:ReEncryptTo",
      ]
      resources = [var.ebs_kms_key_arn]
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["ec2.${local.region}.amazonaws.com"]
      }
    }
  }

  # CreateGrant is the one that actually unblocks the attach: EC2 needs a grant
  # on the key to decrypt the volume's data key for the life of the attachment,
  # and it creates that grant using the caller's credentials -- this role's.
  # GrantIsForAWSResource confines it to grants an AWS service creates for
  # itself, so it is not a general-purpose escalation. Separate statement because
  # kms:ViaService and GrantIsForAWSResource cannot share one condition block.
  dynamic "statement" {
    for_each = var.ebs_kms_key_arn != null ? [1] : []
    content {
      sid       = "KMSDataVolumeCreateGrant"
      effect    = "Allow"
      actions   = ["kms:CreateGrant"]
      resources = [var.ebs_kms_key_arn]
      condition {
        test     = "Bool"
        variable = "kms:GrantIsForAWSResource"
        values   = ["true"]
      }
    }
  }

  # Deploy bundles live in the app pipeline's artifact bucket; the read grant
  # for the CodeDeploy agent is attached to this role by the app-pipeline
  # module, which owns that bucket.

  # ECR: pull the digest-pinned Gramps Web image. GetAuthorizationToken cannot
  # be resource-scoped (it mints a registry-wide token); the actual pull actions
  # are scoped to our repository.
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "ECRPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = [aws_ecr_repository.gramps.arn]
  }

  # SSM parameters: read only, scoped to our path.
  statement {
    sid    = "SSMParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [
      "arn:aws:ssm:${local.region}:${local.account_id}:parameter/gramps-web/${var.env}/*",
    ]
  }

  # Watchdog markers: lets the instance write its own cause-attribution
  # markers (watchdog_markers.tf) for the availability Lambda to read back.
  # Scoped to exactly the two marker parameters, not the whole path above --
  # that grant is read-only; this is a write, so least privilege keeps it to
  # only the ARNs the instance actually needs to put.
  statement {
    sid       = "WatchdogMarkers"
    effect    = "Allow"
    actions   = ["ssm:PutParameter"]
    resources = [aws_ssm_parameter.last_rightsize.arn, aws_ssm_parameter.last_health_watchdog.arn]
  }

  # Health watchdog: lets the instance mark ITSELF Unhealthy so the ASG
  # replaces it when the app is dead but EC2 status checks pass. Scoped to
  # this ASG only.
  #
  # The ARN is CONSTRUCTED rather than read from aws_autoscaling_group.this.arn,
  # which would be the obvious way to write it. Referencing the resource makes
  # this policy depend on the ASG, and the ASG depends_on this policy (asg.tf
  # explains why: an instance must never boot against a policy that names the
  # wrong volume), so the reference is a dependency cycle. Terraform reports it
  # as one; there is no ordering that satisfies both.
  #
  # Constructing it is sound because the name is a constant, not a computed
  # value. The wildcard covers the account-scoped UUID segment AWS generates,
  # which is the only part not known at plan time, and "an ASG in this account
  # and region named gramps-web" is exactly this ASG.
  statement {
    sid       = "ASGSetSelfUnhealthy"
    effect    = "Allow"
    actions   = ["autoscaling:SetInstanceHealth"]
    resources = ["arn:aws:autoscaling:${local.region}:${local.account_id}:autoScalingGroup:*:autoScalingGroupName/gramps-web"]
  }

  # KMS: allow decrypt via the AWS-managed aws/ssm key.
  # AWS-managed key ARNs can't be resolved at plan time without a data source;
  # using "*" here is safe because the effective scope is this account/region
  # and the instance can only decrypt parameters it can already GetParameter.
  statement {
    sid       = "KMSDecryptSSM"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${local.region}.amazonaws.com"]
    }
  }

  # CloudFront: lets validate_service.sh (the CodeDeploy ValidateService hook)
  # bust the static-asset cache behaviors (modules/edge/cloudfront_primary.tf)
  # after a deploy, so a version bump that changes global.css/fonts/images/
  # webawesome-styles/manifest.json without changing their filename doesn't
  # serve a stale copy for up to a day. The distribution ID itself is
  # unknown to this module at plan time -- it lives in modules/edge, which
  # already depends on this module for the origin EIP, so a reference back
  # into edge from here would be a dependency cycle (see modules/edge/ssm.tf,
  # which publishes the ID to SSM instead so validate_service.sh can look it
  # up at deploy time). The wildcard resource ID is the accepted cost of that:
  # this account has exactly one CloudFront distribution this stack manages,
  # and the action itself (busting a cache) is low-risk.
  statement {
    sid       = "CloudFrontInvalidate"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = ["arn:aws:cloudfront::${local.account_id}:distribution/*"]
  }

  # rightsize-watchdog.sh resolves the ASG's instance requirements to types and
  # compares Spot prices. All three are read-only and support no resource-level
  # permissions.
  statement {
    sid    = "RightsizePriceReads"
    effect = "Allow"
    actions = [
      "ec2:DescribeSpotPriceHistory",
      "ec2:GetInstanceTypesFromInstanceRequirements",
      "autoscaling:DescribeAutoScalingGroups",
    ]
    resources = ["*"]
  }

  # Lets health-watchdog.sh publish disk/memory usage for the status page's
  # host_metrics panel -- DiskUsedPercent/MemUsedPercent, or (with
  # status_volume_metrics also on) DiskUsedBytes/DiskTotalBytes in place of
  # DiskUsedPercent. Scoped by the cloudwatch:namespace condition (matching
  # monitoring/lambda.tf's PutMetrics statement) rather than by resource --
  # PutMetricData has no resource-level ARN to scope to. Gated like the
  # other optional grants in this policy (KMSDataVolume, BedrockInvoke):
  # present only when the feature that needs it (status_host_metrics) is
  # on; status_volume_metrics needs no separate gate here since it can't be
  # true without status_host_metrics (enforced in the root variable).
  dynamic "statement" {
    for_each = var.status_host_metrics ? [1] : []
    content {
      sid       = "PutHostMetrics"
      effect    = "Allow"
      actions   = ["cloudwatch:PutMetricData"]
      resources = ["*"]
      condition {
        test     = "StringEquals"
        variable = "cloudwatch:namespace"
        values   = ["GrampsWeb"]
      }
    }
  }

  # CloudWatch agent (build/ami/install.sh): ship codedeploy-agent's log,
  # gramps-deploy.log, and cloud-init's logs to logs.tf's one log group.
  # CreateLogGroup is granted even though Terraform already creates the group,
  # because the agent's own log-group-exists check runs regardless and would
  # otherwise fail loudly on every stream write.
  statement {
    sid    = "InstanceLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = [
      aws_cloudwatch_log_group.instance.arn,
      "${aws_cloudwatch_log_group.instance.arn}:*",
    ]
  }

  # Bedrock: invoke the AI chat model. Present only when the assistant is
  # enabled -- a disabled feature grants nothing. The model ID and invoke
  # region come from var.llm, so this grant can never drift from what
  # the app calls. Cross-region inference profiles (us./eu./apac./jp./au./
  # global. prefix) route to AWS-owned foundation models in the profile's
  # member regions; the foundation-model ARN carries no account field and is
  # region-wildcarded so the grant tracks that routing without
  # hand-maintaining a member-region list. Wildcarding grants nothing beyond
  # "this one model, wherever the profile invokes it". A bare (non-profile)
  # model ID passes through both branches unchanged: its profile ARNs simply
  # never match.
  dynamic "statement" {
    for_each = var.llm.enabled ? [1] : []
    content {
      sid    = "BedrockInvoke"
      effect = "Allow"
      actions = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
      ]
      resources = concat(
        [for r in local.llm_invoke_regions : "arn:aws:bedrock:${r}:${local.account_id}:inference-profile/${var.llm.model_id}"],
        ["arn:aws:bedrock:*::foundation-model/${replace(var.llm.model_id, "/^(us|eu|apac|jp|au|global)\\./", "")}"],
      )
    }
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "gramps-web-instance"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "gramps-web-instance"
  role = aws_iam_role.instance.name
}

moved {
  from = aws_iam_role.instance[0]
  to   = aws_iam_role.instance
}

moved {
  from = aws_iam_role_policy_attachment.ssm_core[0]
  to   = aws_iam_role_policy_attachment.ssm_core
}

moved {
  from = aws_iam_role_policy.instance[0]
  to   = aws_iam_role_policy.instance
}
