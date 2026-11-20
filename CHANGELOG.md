# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows [Semantic Versioning](https://semver.org/). Until 1.0.0, a minor release may include breaking changes.

## [1.8.1] - 2026-11-20

### Fixed

- The proxy refused to start with the module's own origin secret. nginx stores each key of the secret map in a hash bucket of `map_hash_bucket_size` bytes, 64 by default, and the 48-character secret does not fit: `could not build map_hash, you should increase map_hash_bucket_size: 64`. The new proxy container restarted in a loop and the first v1.8.0 deploy failed at ApplicationStart (502 until CodeDeploy rolled back). `nginx.conf` sets `map_hash_bucket_size 128;`, and `origin_secret` and `origin_secret_extra` values are limited to 32 to 64 letters and digits, which fit. The proxy test of v1.8.0 used a short secret, so it never loaded a real one.
- `application_start.sh` watches the proxy for a few seconds after `up -d` and fails with its last 30 log lines if it is not staying up or the reload fails, so the error shows in the deployment output.

### Added

- `scripts/tests/test_proxy_stack.sh` brings the real compose file up in Docker with the rendered origin secret maps, runs `application_start.sh` and `validate_service.sh`, and checks the proxy stays up and answers on 443 and the loopback listener in log mode and, after a recreate with changed maps, in enforce mode. The pre-commit script-test hook also runs when `nginx.conf` or `docker-compose.yml` changes.
- `validate_service.sh` takes `VALIDATE_URL` and `VALIDATE_TLS_URL` for tests.

### Upgrade

- Move the module ref to `v1.8.1`; `source_branch` stays `release-1.8`, which moves with the tag. The plan has no changes (the fix is in the deploy bundle and the AMI build's scripts). Then deploy (`scripts/deploy.sh --root <root> gramps`). A root that set `origin_secret` or `origin_secret_extra` outside 32 to 64 characters must change them.

## [1.8.0] - 2026-11-19

### Added

- The `gramps-web-ami` build runs weekly (Sundays 06:00 UTC) and when the app image for `gramps.version` is pushed to ECR. `ami_auto_build = false` turns both off; a pinned `ami_ids` also does.
- `scripts/adopt-amis.sh` runs after a passing build. It writes a launch template version per architecture with the newest AMI (`ImageId` only), repins the Auto Scaling group to the new version numbers, deletes versions beyond the newest five (keeping the default and the pinned one), and starts an instance refresh only when a running instance's AMI is older than `ami_max_age_days` (new, default 14). It skips while a refresh runs or the refresh alarm is in ALARM, and holds a template the group was pinned behind by hand (logged, `AmiAdoptionHeld`, alarm `gramps-web-ami-held`) while adopting the other.
- `ami_max_age_days` and `ami_auto_build`.
- The build publishes `GrampsWeb` `AmiAgeDays`. Alarms `gramps-web-ami-age` (over twice `ami_max_age_days`) and `gramps-web-ami-failed` (a failed build) notify the alerts topic.
- `build/ami/smoke.sh` runs on the Packer builder before the snapshot and fails the build when docker is not active, a pinned or the `gramps.version` image is missing, a baked script or unit is missing or disabled, or `dnf-automatic` is not set to security updates.
- The image installs `dnf-automatic` with `upgrade_type = security` and `apply_updates = yes`.
- The origin secret: a `random_password` in the SSM parameter `/gramps-web/<env>/origin-secret`, sent by CloudFront as `X-Origin-Verify`. The proxy checks it on 443 and, with `origin_secret_enforce = true`, answers 403 to a missing or wrong value; by default it only logs the result. The proxy also listens on `127.0.0.1:80` for the on-instance health checks.
- `origin_secret_enforce` (default false), `origin_secret` (override, for rotation) and `origin_secret_extra` (further accepted values, for rotation). The README's "Origin secret" gives the rollout and the three-step rotation.
- A CloudFront response headers policy (HSTS for one year, `nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, `X-Frame-Options: SAMEORIGIN`, a `frame-ancestors 'self'` CSP) on the app, its static assets and the error pages.
- Outputs `launch_template_ids`, `instance_role_arn`, `origin_secret` (compute) and `alert_topic_arn` (monitoring), consumed by the root.
- The instance policy gains `autoscaling:DescribeAutoScalingInstances`.
- Tests: `clean-amis.sh`, `adopt-amis.sh`, `spot-drain.sh`, `health-watchdog.sh`, `smoke.sh`, the origin secret on the instance, and the proxy in Docker (`scripts/tests`), and the new resources in `tests/`.
- The README section "Base AMI", the origin secret and its rotation, and the IMDS hop-limit risk.

### Changed

- Launch templates ignore changes to `image_id` and are replaced only when `ami_ids` changes. `ami_ids` seeds a template when it is created.
- `gramps-spot-drain` also runs as the unit's `ExecStop` (`TimeoutStopSec=60`): an ASG termination (instance refresh, scale-in) now stops the containers, syncs and detaches the data volume, as a Spot notice did. A reboot is left to systemd.
- `clean-amis.sh` keeps every AMI that any launch template version references, not just `$Latest` and `$Default`.
- Packer connects to the builder over SSM Session Manager (`ssh_interface = "session_manager"`) in a security group with no inbound rule. The build role loses `CreateSecurityGroup`, `AuthorizeSecurityGroupIngress` and `DeleteSecurityGroup`, `ModifyImageAttribute` is limited to images in the region, and it gains scoped `ssm:StartSession` (builders only) and the grants `adopt-amis.sh` needs (template versions of the two templates, the group, `iam:PassRole` of the instance role to EC2, `PutMetricData` in the `GrampsWeb` namespace). The builder role gains `AmazonSSMManagedInstanceCore`. The CodeBuild image installs the pinned `session-manager-plugin`.
- `validate_service.sh` reads the app on the loopback listener and requires `:443` to complete a TLS handshake. The baked health watchdog needs no change: its `http://localhost/` fallback reaches the same listener.
- Move `source_branch` along with the tag (`release-1.8`).

### Upgrade

- `terraform init -upgrade`, then apply. The plan adds the origin secret and its parameter, the response headers policy, the builder security group, the build's schedule and push rules, event role and two alarms, `terraform_data.image_pin`, and two build role policies; it updates the CloudFront distribution (the origin header and the policy on the app, static and error behaviors), the error pages bucket policy, the build project (environment) and the pipeline and frontend build (source branch), and the build and instance policies. It changes no launch template or Auto Scaling group, so it starts no instance refresh.
- The proxy only logs the origin secret until you enforce it, so no apply and no pipeline run can lock the site out. After the apply: `scripts/deploy.sh --root <root> gramps`; confirm CloudFront is Deployed (`aws cloudfront get-distribution --id <primary_distribution_id> --query Distribution.Status --output text`); on the instance, `docker compose --env-file /opt/gramps/.env -f /opt/gramps/docker-compose.yml logs --tail 500 proxy | grep -c 'origin_secret=1'` must be positive and the same with `origin_secret=0` zero; then set `origin_secret_enforce = true`, apply, and deploy again.
- A root that pins `ami_ids` keeps its pin and gets no automatic builds. To adopt, remove the pin: the launch templates keep the AMIs they have, and the first build afterwards advances them.
- The drain, `dnf-automatic`, the smoke check and the proxy secret reach an instance with the next AMI and bundle: run `scripts/deploy.sh gramps` for the proxy (it fetches the secret from SSM, so apply first), and the first build adopts the AMI. The refresh the first build starts happens only when the running AMI is older than `ami_max_age_days`; otherwise the AMI arrives at the next replacement, or start a refresh yourself (README, "Base AMI").
- Move `source_branch` along with the tag (`release-1.8`).

## [1.7.0] - 2026-11-12

### Changed

- The rightsize watchdog calls keel v0.3.0's shared `rightsize-check` (vendored in `scripts/keel`, baked into the AMI as `/usr/local/bin/keel-rightsize-check`) for the decision. It replaces only when the cheapest eligible Spot pool costs at most 0.75 of this instance's type and the Spot placement score for that pool is at least 5 out of 10. Any API failure means stay, including an unreadable placement score.
- The watchdog logs any check failure other than an ordinary decline.
- The instance policy's `RightsizePriceReads` statement adds `ec2:GetSpotPlacementScores`.
- `modules/status`, `modules/availability` and `modules/monitoring` use terraform-aws-status-page v0.7.0. The `moved` blocks follow the availability module's renamed schedule rule, target and Lambda permission.

### Fixed

- The rightsize watchdog drains only when `REGION`, `LAST_RIGHTSIZE_PARAM` and `COMPOSE_DIR` are all set. A missing `LAST_RIGHTSIZE_PARAM` used to abort after the containers stopped and the data volume detached.

### Upgrade

- Rebuild the AMI and pin the new ids; the rightsize check ships in the image.
- `terraform init -upgrade`, then apply. The availability schedule rule and Lambda permission are replaced; the instance policy, Lambda code and environment update in place.
- Move `source_branch` along with the tag (`release-1.7`).

## [1.6.3] - 2026-11-11

### Changed

- `gramps.version` defaults to 26.11.2. Gramps Web 26.11.1 and 26.11.2 change only the frontend (drag-and-drop reordering, search as you type, a MapLibre worker fix, the age-at-death column); the API and database schema are unchanged.
- The README's "Upgrading Gramps Web" covers release notes, the pre-upgrade snapshot, the base AMI and rollback.

### Upgrade

- `terraform init -upgrade`, then apply. A root that sets `gramps.version` changes nothing; one that follows the default updates the build projects' and the status Lambda's `GRAMPS_WEB_VERSION`; nothing is replaced. Run the deploy to roll the image out.
- Move `source_branch` along with the tag (`release-1.6`).

## [1.6.2] - 2026-11-11

### Fixed

- The data volume is formatted only when `blkid` exits 2 (no filesystem). Any other `blkid` failure aborts user data instead of running `mkfs.ext4` over a volume that may hold data.
- The AMI-build role's `DeleteSnapshot` and `DeregisterImage` are limited to resources tagged `Name = gramps-web-base`, and `DeleteVolume`, `DeleteSecurityGroup` and `ModifyInstanceAttribute` to `Name = packer-builder-gramps-web`, so a build cannot delete the data volume or its snapshots. The Packer template tags the builder's volumes to match.
- Stale comments and README refs in `modules/ami-build`, `modules/web-build`, `modules/compute` and the examples.

### Changed

- The ECR lifecycle policy keeps 15 tagged manifests (3 pushes) instead of 40, which should save about $1 a month (estimate from 20 GB-months at $2.05).
- The `spot` variable description records the measured reclaim rate and outage length.
- `modules/storage` uses terraform-aws-keel v0.2.1, which guards the data volume's keys and the backup vault with `prevent_destroy`. `modules/status`, `modules/availability` and `modules/monitoring` use terraform-aws-status-page v0.3.2.

### Upgrade

- `terraform init -upgrade`, then apply. The ECR lifecycle policy, the AMI-build role policy, the dashboard and query definitions and the Lambda code change; nothing is replaced.
- Move `source_branch` along with the tag (`release-1.6`).

## [1.6.1] - 2026-11-04

### Fixed

- The status page's Spot recovery split times a reclaim from the interruption warning instead of the outage start, which read 0 s of capacity wait on every reclaim. `modules/status`, `modules/availability` and `modules/monitoring` use terraform-aws-status-page v0.3.1.

### Upgrade

- `terraform init -upgrade`, then apply. The availability and status Lambdas and the status page object change; nothing is replaced.

## [1.6.0] - 2026-11-02

### Added

- The deploy hook prunes unused Docker images after a healthy deploy, so the root volume no longer fills with superseded images.

### Changed

- `modules/storage` delegates the data volume, its key and AWS Backup to `modules/data-volume` of terraform-aws-keel (v0.2.0). `modules/monitoring` delegates the backup-failure alert, the disk alarm and the availability dashboard to `modules/host-alarms` of terraform-aws-status-page (v0.3.0). `moved` blocks map every existing address, so no resource is replaced. The media bucket stays in `modules/storage`.
- The disk alarm gains OK notifications to the alerts topic, and with `status.volume_metrics` off it treats missing data as not breaching instead of ignoring it, so a silent publisher leaves the alarm OK.
- `modules/status` and `modules/availability` use terraform-aws-status-page v0.3.0.
- The `asg.tf` memory comment records the measured peak of about 2.0 GiB with 3 workers.

### Upgrade

1. Run `terraform apply` with the `release-1.6` branch as `source_branch`. The plan is moves only, plus the disk alarm's OK notifications and missing-data handling.
2. Run `scripts/deploy.sh gramps`.
3. No AMI rebuild is needed.

## [1.5.0] - 2026-11-01

### Fixed

- CloudFront returned 504s on `/api` since 1.4.0: gunicorn terminated the origin TLS, so one worker serving a slow request (a cold thumbnail, an export) could not accept new connections, and CloudFront abandons a connect after 2 s.

### Changed

- An nginx proxy (`proxy`, pinned `nginx:1.30-alpine`) terminates the origin TLS and forwards to gunicorn over the compose network. The origin certificate is mounted into it instead of grampsweb, and the renewal timer reloads nginx (`gramps-origin-cert --reload`, was `--restart`) instead of restarting the app.
- gunicorn runs 3 workers (was 1). Gramps Web API 3.25 starts workers with `--preload`, so they share memory; measured use on 26.11.0 with one worker was 1.45 GiB of 4 GiB.
- `gramps.version` defaults to 26.11.0. Gramps Web 26.11.0 removes semantic search; no input in this module referred to it.
- The AMI build pre-pulls the proxy image, and `scripts/check-pins.sh` tracks its stable line.
- README Cost section: the table adds an estimated minimal column and the origin certificate row, and the `active` input's sleeping cost reads 10 to 16 USD. The README no longer lists the archive provider, which no resource uses.

### Upgrade

1. Run `terraform apply` with the `release-1.5` branch as `source_branch`.
2. Run `scripts/deploy.sh gramps`. Docker pulls the nginx image from Docker Hub once.
3. Rebuild the AMI and pin it, which restores the pre-pull.

## [1.4.0] - 2026-10-26

### Changed

- CloudFront reaches the origin over HTTPS (`https-only`) with an ACM exportable public certificate for `origin.<primary_domain>`, issued in the instance's region. The instance exports it at deploy time (`gramps-origin-cert`), gunicorn serves it on port 443, and a daily systemd timer re-exports and restarts the app after ACM renews it. ACM bills 7 USD at issuance and at each renewal; certificates last 198 days.
- The origin security group's ingress rule moves from port 80 to port 443 (`origin_http_from_cloudfront` becomes `origin_https_from_cloudfront`). The instance policy gains `ACMOriginCertificate`, scoped to the one certificate.
- The primary behavior's origin request policy is AllViewerExceptHostHeader (was AllViewer). With Host forwarded, CloudFront would check the origin certificate against the viewer's hostname instead of `origin.<primary_domain>`. The app builds its links from `BASE_URL`, so it sees `origin.<primary_domain>` as its Host.
- The health watchdog accepts either `https://localhost/` or `http://localhost/`, so an older bundle and a newer AMI, or the reverse, do not mark the instance Unhealthy.
- `examples/minimal` and the cross-account backup guide use terraform-aws-keel v0.1.2.

### Upgrade

1. Rebuild the AMI from the `release-1.4` branch, pin the new IDs in `ami_ids`, and let the instance refresh finish. The previous AMI's watchdog probes only `http://localhost/` and would mark the instance Unhealthy every ten minutes once the app serves TLS.
2. Run `terraform apply`. The site shows the maintenance page from this point, because CloudFront now requires HTTPS from an origin still serving HTTP.
3. Run `scripts/deploy.sh gramps` to roll the new bundle. The maintenance page clears when the deploy passes.

## [1.3.0] - 2026-10-26

### Changed

- The derived memory floor is 4 GiB regardless of `llm.enabled`; it was 2 GiB with the assistant off. Measured peak use is about 1.6 GiB, and the app runs the same process count with the assistant off. On-Demand in us-east-1, the cheapest eligible type moves from t4g.small ($0.0168/h) to t4g.medium ($0.0336/h). `instance_requirements` still accepts a 2 GiB floor.

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
