data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "status" {
  name               = "gramps-web-status"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = {
    Name = "gramps-web-status"
  }
}

data "aws_iam_policy_document" "status" {
  statement {
    sid     = "OwnLogs"
    effect  = "Allow"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "${aws_cloudwatch_log_group.status_lambda.arn}:*",
    ]
  }

  # Describe* calls don't support resource-level scoping. Covers the host panel
  # (instance + ASG) and the image panel (AMI).
  statement {
    sid    = "DescribeInfra"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeImages",
      "autoscaling:DescribeAutoScalingGroups",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "DescribeVolumes"
    effect    = "Allow"
    actions   = ["ec2:DescribeVolumes"]
    resources = ["*"]
  }

  # ListDeployments is scopable to the deployment group; BatchGetDeployments is
  # scoped by individual deployment (arn:...:deployment:<id>), and deployment
  # IDs aren't known ahead of time, so that half is wildcarded within this
  # account/region rather than opened up to "*".
  statement {
    sid    = "Deployments"
    effect = "Allow"
    actions = [
      "codedeploy:ListDeployments",
      "codedeploy:BatchGetDeployments",
    ]
    resources = [
      "arn:aws:codedeploy:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:deploymentgroup:${var.codedeploy_app_name}/${var.codedeploy_deployment_group_name}",
      "arn:aws:codedeploy:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:deployment:*",
    ]
  }

  # Joins each CodeDeploy deployment to the commit that triggered it (see
  # pipeline_commits() in lambda/status.py).
  statement {
    sid       = "PipelineCommits"
    effect    = "Allow"
    actions   = ["codepipeline:ListActionExecutions"]
    resources = ["arn:aws:codepipeline:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:${var.codepipeline_name}"]
  }

  statement {
    sid       = "EcrDescribeImages"
    effect    = "Allow"
    actions   = ["ecr:DescribeImages"]
    resources = [var.ecr_repository_arn]
  }

  # The episodes and Spot interruption log groups are owned by the monitoring
  # module; their ARNs are constructed from the shared literal names (see
  # local.episodes_log_group) rather than passed in. The grant covers the
  # episodes and changes streams of the first.
  statement {
    sid     = "IncidentLog"
    effect  = "Allow"
    actions = ["logs:FilterLogEvents"]
    resources = [
      "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:${local.episodes_log_group}:*",
      "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:${local.spot_interruptions_log_group}:*",
    ]
  }

  # GetMetricData supports neither resource-level scoping nor a namespace
  # condition key, so it is a single "*" statement covering the reliability
  # panel's SiteUp series, the storage panel's S3 bucket metrics, the assistant
  # panel's Bedrock token counts (in llm_region), and host_metrics.
  statement {
    sid       = "ReadMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:GetMetricData"]
    resources = ["*"]
  }

  # ListBackupJobs/ListCopyJobs aren't resource-scopable, so they stay a
  # wildcard grant; DescribeBackupVault does support it (see the statement
  # below). Read-only; the panel itself is absent from the response whenever
  # BACKUP_VAULT_NAME is empty, so an unused grant here is harmless.
  statement {
    sid       = "Backups"
    effect    = "Allow"
    actions   = ["backup:ListBackupJobs", "backup:ListCopyJobs"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.backup_vault_name != "" ? [1] : []
    content {
      sid     = "DescribeBackupVault"
      effect  = "Allow"
      actions = ["backup:DescribeBackupVault"]
      # The local vault, plus the destination vault when it is in THIS account
      # under a different region (backup.mode = cross_region): the local vault
      # ARN is pinned to this region, so a same-account destination in another
      # region needs its own entry here. A cross_account destination is a
      # different account's vault; DescribeBackupVault on it goes through the
      # assumed role below instead (AWS rejects cross-account vault reads
      # regardless of an IAM grant here).
      resources = concat(
        ["arn:aws:backup:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:backup-vault:${var.backup_vault_name}"],
        var.backup_copy_vault_arn != "" && var.backup_dest_reader_role_arn == "" ? [var.backup_copy_vault_arn] : [],
      )
    }
  }

  # Absent unless backup.mode = cross_account: the destination vault lives in
  # another account, and DescribeBackupVault there has to run as a principal in
  # that account. See keel's backup-vault-account module for the role this
  # assumes.
  dynamic "statement" {
    for_each = var.backup_dest_reader_role_arn != "" ? [1] : []
    content {
      sid       = "AssumeVaultReaderRole"
      effect    = "Allow"
      actions   = ["sts:AssumeRole"]
      resources = [var.backup_dest_reader_role_arn]
    }
  }

  # Cost Explorer actions are not resource-scopable. Present only when the cost
  # panel is enabled -- every call to GetCostAndUsage bills $0.01 regardless of
  # whether the grant exists, so this stays off by default like the panel.
  dynamic "statement" {
    for_each = var.cost_enabled ? [1] : []
    content {
      sid       = "Cost"
      effect    = "Allow"
      actions   = ["ce:GetCostAndUsage"]
      resources = ["*"]
    }
  }
}

resource "aws_iam_role_policy" "status" {
  name   = "gramps-web-status"
  role   = aws_iam_role.status.id
  policy = data.aws_iam_policy_document.status.json
}
