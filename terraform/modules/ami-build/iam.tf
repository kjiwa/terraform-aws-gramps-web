data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ami_build" {
  name               = "${local.name}-build"
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = {
    Name = "${local.name}-build"
  }
}

# The Packer amazon-ebs documented minimal policy plus its spot additions
# (CreateLaunchTemplate/DeleteLaunchTemplate/CreateFleet, and
# DescribeSpotPriceHistory for spot_price=auto), fenced to the build region.
# This is the module's real privilege: it can launch instances, and PassRole
# below lets it hand the builder its ECR-read instance profile -- but that
# PassRole grant is scoped to exactly that one role, and Stop/Terminate are
# scoped to the tag the template stamps on its own builders.
#
# Trimmed from the documented set, restore on an AccessDenied naming one:
# GetPasswordData (Windows), CopyImage (ami_regions), ModifySnapshotAttribute
# (snapshot sharing), AttachVolume / DetachVolume /
# CreateVolume (chroot-style builders). iam:CreateServiceLinkedRole for Spot
# is deliberately absent: AWSServiceRoleForEC2Spot already exists in any
# account that has run this stack's Spot ASG or a workstation Packer build.
data "aws_iam_policy_document" "ami_build" {
  statement {
    sid     = "Logs"
    effect  = "Allow"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      aws_cloudwatch_log_group.build.arn,
      "${aws_cloudwatch_log_group.build.arn}:*",
    ]
  }

  # Pull source through the CodeConnections GitHub app. If IAM rejects the
  # codeconnections: prefix in your partition, swap to codestar-connections:.
  statement {
    sid       = "UseConnection"
    effect    = "Allow"
    actions   = ["codeconnections:GetConnectionToken", "codeconnections:GetConnection", "codeconnections:UseConnection"]
    resources = [var.connection_arn]
  }

  statement {
    sid    = "PackerBuild"
    effect = "Allow"
    actions = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:CreateFleet",
      "ec2:CreateImage",
      "ec2:CreateKeyPair",
      "ec2:CreateLaunchTemplate",
      "ec2:CreateSecurityGroup",
      "ec2:CreateSnapshot",
      "ec2:CreateTags",
      "ec2:DeleteKeyPair",
      "ec2:DeleteLaunchTemplate",
      "ec2:DeleteSecurityGroup",
      "ec2:DeleteSnapshot",
      "ec2:DeleteVolume",
      "ec2:DeregisterImage",
      "ec2:DescribeImageAttribute",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      # The next two are Packer-idle: scripts/clean-amis.sh's post_build step
      # (buildspec.yml) reads them to build its keep-set (an AMI referenced by
      # a launch template survives even if superseded).
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:DescribeRegions",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSnapshots",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
      "ec2:DescribeTags",
      "ec2:DescribeVolumes",
      "ec2:ModifyImageAttribute",
      "ec2:ModifyInstanceAttribute",
      "ec2:RegisterImage",
      "ec2:RunInstances",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # Only instances the template tagged as its own builders (run_tags in
  # gramps-ami.pkr.hcl); the build cannot stop or kill the gramps-web fleet.
  statement {
    sid       = "PackerCleanup"
    effect    = "Allow"
    actions   = ["ec2:StopInstances", "ec2:TerminateInstances"]
    resources = ["arn:aws:ec2:${var.region}:${local.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Name"
      values   = ["packer-builder-gramps-web"]
    }
  }

  # RunInstances with an iam_instance_profile requires the caller to be able
  # to pass that role to EC2. Scoped to the one role the builder attaches
  # (ami_builder below), not a wildcard.
  statement {
    sid       = "PassBuilderRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.ami_builder.arn]
  }

  # Packer's amazon-ebs builder resolves iam_instance_profile by name via
  # GetInstanceProfile before it ever calls RunInstances/PassRole. Scoped to
  # the same one role.
  statement {
    sid       = "ReadBuilderInstanceProfile"
    effect    = "Allow"
    actions   = ["iam:GetInstanceProfile"]
    resources = [aws_iam_instance_profile.ami_builder.arn]
  }
}

resource "aws_iam_role_policy" "ami_build" {
  name   = "${local.name}-build"
  role   = aws_iam_role.ami_build.id
  policy = data.aws_iam_policy_document.ami_build.json
}

# Instance profile Packer attaches to the builder instance (gramps-ami.pkr.hcl,
# both sources) so install.sh's pull_images can authenticate to ECR and bake
# the grampsweb image. Named by a stable constant rather than referencing this
# resource's ARN: the Packer template is HCL evaluated by Packer itself, with
# no visibility into Terraform state, so the two sides can only agree on a
# literal string.
data "aws_iam_policy_document" "ami_builder_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ami_builder" {
  name               = "gramps-web-ami-builder"
  assume_role_policy = data.aws_iam_policy_document.ami_builder_assume.json

  tags = {
    Name = "gramps-web-ami-builder"
  }
}

# GetAuthorizationToken is registry-wide and cannot be resource-scoped; the
# pull itself is scoped to the one repository the AMI bakes an image from.
data "aws_iam_policy_document" "ami_builder" {
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
    resources = [var.ecr_repository_arn]
  }
}

resource "aws_iam_role_policy" "ami_builder" {
  name   = "gramps-web-ami-builder"
  role   = aws_iam_role.ami_builder.id
  policy = data.aws_iam_policy_document.ami_builder.json
}

resource "aws_iam_instance_profile" "ami_builder" {
  name = "gramps-web-ami-builder"
  role = aws_iam_role.ami_builder.name
}
