# --- CodeBuild role ----------------------------------------------------------

data "aws_iam_policy_document" "build_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "build" {
  name               = "${local.name}-build"
  assume_role_policy = data.aws_iam_policy_document.build_assume.json

  tags = {
    Name = "${local.name}-build"
  }
}

data "aws_iam_policy_document" "build" {
  statement {
    sid     = "Logs"
    effect  = "Allow"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      aws_cloudwatch_log_group.build.arn,
      "${aws_cloudwatch_log_group.build.arn}:*",
    ]
  }

  # Pipeline hands source in and takes the bundle out via the artifact bucket.
  statement {
    sid       = "Artifacts"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
  }

  # ECR auth token is registry-wide and cannot be resource-scoped.
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Push the multi-arch image and read back its digest, scoped to our repo.
  statement {
    sid    = "ECRPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
    ]
    resources = [var.ecr_repository_arn]
  }
}

resource "aws_iam_role_policy" "build" {
  name   = "${local.name}-build"
  role   = aws_iam_role.build.id
  policy = data.aws_iam_policy_document.build.json
}

# --- CodePipeline role -------------------------------------------------------

data "aws_iam_policy_document" "pipeline_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "pipeline" {
  name               = "${local.name}-pipeline"
  assume_role_policy = data.aws_iam_policy_document.pipeline_assume.json

  tags = {
    Name = "${local.name}-pipeline"
  }
}

data "aws_iam_policy_document" "pipeline" {
  statement {
    sid       = "Artifacts"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketLocation", "s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    sid       = "UseConnection"
    effect    = "Allow"
    actions   = ["codeconnections:UseConnection"]
    resources = [var.connection_arn]
  }

  statement {
    sid       = "RunBuild"
    effect    = "Allow"
    actions   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
    resources = [aws_codebuild_project.build.arn]
  }

  # CodeDeploy uses the deployment group's own service role; the pipeline only
  # creates and tracks deployments, so no iam:PassRole is needed here.
  statement {
    sid    = "Deploy"
    effect = "Allow"
    actions = [
      "codedeploy:CreateDeployment",
      "codedeploy:GetDeployment",
      "codedeploy:GetApplication",
      "codedeploy:GetApplicationRevision",
      "codedeploy:RegisterApplicationRevision",
    ]
    resources = [
      "arn:aws:codedeploy:${local.region}:${local.account_id}:application:${var.codedeploy_app_name}",
      "arn:aws:codedeploy:${local.region}:${local.account_id}:deploymentgroup:${var.codedeploy_app_name}/${var.codedeploy_deployment_group_name}",
    ]
  }

  statement {
    sid       = "DeployConfig"
    effect    = "Allow"
    actions   = ["codedeploy:GetDeploymentConfig"]
    resources = ["arn:aws:codedeploy:${local.region}:${local.account_id}:deploymentconfig:*"]
  }
}

resource "aws_iam_role_policy" "pipeline" {
  name   = "${local.name}-pipeline"
  role   = aws_iam_role.pipeline.id
  policy = data.aws_iam_policy_document.pipeline.json
}

# --- Instance access to deploy bundles ----------------------------------------

# CodePipeline's Deploy stage stages the CodeDeploy bundle in this pipeline's
# artifact bucket, and the CodeDeploy agent fetches it with the instance
# profile. The grant lives here, where the bucket is owned, and attaches to the
# instance role from the compute module -- app-pipeline already depends on
# compute, so this direction has no cycle and no reconstructed bucket names.
data "aws_iam_policy_document" "instance_artifacts" {
  statement {
    sid    = "S3PipelineArtifacts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
}

resource "aws_iam_role_policy" "instance_artifacts" {
  name   = "${local.name}-pipeline-artifacts-read"
  role   = var.instance_role_name
  policy = data.aws_iam_policy_document.instance_artifacts.json
}
