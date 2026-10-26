# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows [Semantic Versioning](https://semver.org/). Until 1.0.0, a minor release may include breaking changes.

## [Unreleased]

## [1.2.0] - 2026-10-25

### Changed

- The status page and the availability recorder come from [terraform-aws-status-page](https://github.com/kjiwa/terraform-aws-status-page) v0.1.1. This module keeps the Gramps Web plugin (`modules/status/plugin`), the shell's `config.js`, the disk alarm, the dashboard, and the backup alerts.
- `moved` blocks ship for every relocated resource. A consumer's plan shows state moves and no replacements.
- The status shell and `config.js` are Terraform-owned S3 objects, uploaded by `terraform apply`. The shell's source is committed in terraform-aws-status-page. The `web` CodeBuild project no longer publishes the shell or receives a status bucket name, and CloudFront no longer invalidates `/_status`.
- IAM, shipped in this module: the status role and the SNS topic policy come from the core, so their policy text changes. The statement `AllowDiskAlarmPublish` is renamed `AllowAlarmPublish`.
- Breaking: the disabled-panel key `assistant` is now `bedrock`. A consumer's shell configuration that hides panels by key must use the new name.
- Status page: the Deployment panel no longer shows container version rows read from the Gramps API. The Gramps Web version is a Release panel supplied by the plugin.

### Removed

- The status Lambda, the availability Lambda, their tests, JSON schemas, and the status frontend moved to terraform-aws-status-page. `build/web` builds only the CloudFront error pages.
- `STATUS_BUCKET_NAME` from `build/web/publish.sh`.

## [1.1.1] - 2026-10-23

### Changed

- Status page: below three timed Spot outages, the recovery split is replaced by a note giving how many outages carry timing, instead of being hidden.

## [1.1.0] - 2026-10-22

### Added

- Status page: a Retry button on panels that time out.
- Status page: a Changes card under Delivery, with a Deliberate|All toggle.

### Changed

- Status page: the Lambdas read logs with CloudWatch Logs Insights, one query per log group per request, which fixes panels timing out.
- IAM, shipped in this module: the status role gains `logs:StartQuery` and `logs:GetQueryResults` and loses `logs:FilterLogEvents`. Consumers need this module version for the status page to load.
- Status page: Spot is a subsection of the Incidents card, which takes the page's five ranges and pans in the browser. The Absorbed tile and the weekly table are removed.
- Status page: the sections are Service, Delivery, Data, Runtime, and Spend.

### Removed

- Status page: the events lane. A strip cell's readout names its incidents.

## [1.0.0] - 2026-10-22

First stable release. The inputs and outputs below are the supported interface.

### Changed

- Breaking: `repo_url` and `source_branch` have no defaults. Set `repo_url` to your fork and `source_branch` to the `release-<major>.<minor>` branch matching the module ref.

## [0.9.3] - 2026-10-22

### Added

- `docs/teardown.md`, and an `audit_log_retention_days` input in `examples/minimal` so a trial can be torn down.

### Changed

- The `status` variable documents the Lambda concurrency quota the status page needs: at least 110.
- The instance-profile role, its SSM attachment, and its inline policy no longer carry `count`; `moved` blocks carry existing state over, so the plan shows moves and no changes.

### Removed

- The unused `instance_role_arn` input of `modules/compute`.
- The unused `scripts/keel/tf.sh`.
- Unused outputs of the network, app-pipeline, and web-build modules.

### Fixed

- The data volume and the Elastic IP carry `Project = "gramps-web"` explicitly. The instance IAM policy conditions on that tag, so a root without provider `default_tags` no longer hangs at boot.
- `scripts/hygiene.sh` skips binary files instead of printing a `sed` error on them.

## [0.9.2] - 2026-10-21

### Fixed

- The minimal example takes its region from a `region` variable instead of hardcoding one.
- The minimal example names the media bucket at plan time, so audit's `for_each` no longer depends on an unknown value.
- The Quickstart approves the GitHub connection before the full apply, which CodeBuild project creation requires.

## [0.9.1] - 2026-10-21

### Fixed

- `source_branch` documents that it must name a branch, because CodePipeline cannot source a tag. Pin the module to a tag and set `source_branch` to the matching `release-<major>.<minor>` branch.

## [0.9.0] - 2026-10-21

### Added

- Reusable root module for Gramps Web on AWS: one instance on SQLite and EBS behind CloudFront, Spot or On-Demand, with an optional Bedrock chat assistant and an optional status page.
- Backups to a local vault, a second region, or a second AWS account.
- Operator scripts for deploys, backups, restores, volume moves, media cleanup, and AMI cleanup, driven by the module's outputs.
- `examples/minimal`, composing the module with the keel DNS, cost budget, and audit modules.
- Contract tests for the root module, a hygiene check, and pre-commit configuration.

[Unreleased]: https://github.com/kjiwa/terraform-aws-gramps-web/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/kjiwa/terraform-aws-gramps-web/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/kjiwa/terraform-aws-gramps-web/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/kjiwa/terraform-aws-gramps-web/compare/v0.9.3...v1.0.0
[0.9.3]: https://github.com/kjiwa/terraform-aws-gramps-web/compare/v0.9.2...v0.9.3
[0.9.2]: https://github.com/kjiwa/terraform-aws-gramps-web/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/kjiwa/terraform-aws-gramps-web/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/kjiwa/terraform-aws-gramps-web/releases/tag/v0.9.0
