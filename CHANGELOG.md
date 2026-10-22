# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows [Semantic Versioning](https://semver.org/). Until 1.0.0, a minor release may include breaking changes.

## [Unreleased]

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

[Unreleased]: https://github.com/kjiwa/terraform-aws-gramps-web/compare/v0.9.2...HEAD
[0.9.2]: https://github.com/kjiwa/terraform-aws-gramps-web/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/kjiwa/terraform-aws-gramps-web/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/kjiwa/terraform-aws-gramps-web/releases/tag/v0.9.0
