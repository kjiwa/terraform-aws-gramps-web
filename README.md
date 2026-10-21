# Gramps Web on AWS

Self-hosted [Gramps Web](https://www.grampsweb.org/) on AWS: a single
instance (optionally Spot) behind CloudFront, with optional features toggled from config -- an
AI chat assistant backed by Amazon Bedrock and an operational status page --
and everything built and shipped from this repo. The app image is built from the
upstream release plus a configurable set of Gramps addons, pushed to ECR, and
rolled out with CodeDeploy. There is no runtime dependency on external container
registries, which keeps the instance launch path off IPv4-only endpoints.

## One config file per environment

`terraform/config/stack/<env>/terraform.tfvars` is that environment's config. Every
knob lives there: domains and the primary domain, site title, alert email, the
repo/branch the builds pull from, the grampsweb version, the addon list, the
feature toggles below, and the target account. `scripts/tf.sh <env> apply` distributes the values
(CodeBuild env vars, SSM parameters, IAM grants), and
`ENV=<env> scripts/deploy.sh <gramps|web>` ships them:

```sh
edit terraform.tfvars -> scripts/tf.sh <env> apply -> ENV=<env> scripts/deploy.sh gramps|web
```

(`ENV` defaults to prod, so day-to-day prod use is just
`scripts/deploy.sh gramps`.) The apply must precede the deploy: the build
projects and the instance's SSM config are what the apply updates, and the
deploy is what reads them.

Derived, not configured: the Gramps-core version and the addons-source branch
(from `gramps_web_version` at build time), the SES From/MAIL FROM addresses and
error-page fallback title (from the primary domain), bucket names (from the
domain or account ID), instance sizing (from `llm.enabled`, which decides the
memory floor and so which instance sizes are eligible), and the instance's
Bedrock IAM grants (from `llm`, so IAM can never drift from the model the app
calls).

One thing intentionally sits outside tfvars: the state location in
`terraform/config/stack/<env>/backend.hcl`,
`terraform/config/bootstrap/<account>/backend.hcl`, and (for any fork using
`cross_account`) `terraform/config/backup-account/<instance>/backend.hcl`,
because Terraform backend blocks cannot read variables. Those are the only
non-tfvars files a fork edits by hand.

## Features

Each feature is a tfvars toggle; off means its resources do not exist and it
costs nothing.

- `llm.enabled` — AI chat assistant (Bedrock). On: the app
  gets the chat config, the instance role gets an invoke grant
  scoped to exactly the configured model, and the FilterRules addon the
  assistant depends on is baked into the image automatically. Cost is
  per-question Bedrock usage. Flows through `apply` + `deploy.sh gramps`.
- `frontend` / `api` — Gramps Web's own settings, split by where they land:
  `frontend` is the browser runtime config (`window.grampsjsConfig` — DNA
  link, post-login redirect, map styles), `api` is the backend env, including
  `registration` (open/unlisted/closed), which also controls whether the
  register link is shown. Neither is an infra change; both flow through
  `apply` + `deploy.sh gramps`. Upstream options this stack does not name have
  an escape hatch in `api.extra` (bare upstream keys, no `GRAMPSWEB_` prefix);
  the ones it derives instead (tree, database, media, email, queue) are
  denylisted there, each with its reason, in
  `variables.tf`.
- `status.enabled` — operational status page at `/_status`: uptime
  reliability, incidents, host/image/deployment/storage detail, and DR
  posture, gated on the caller's own Gramps Web role. Its static shell
  (`build/web/src/status/`) ships through `deploy.sh web`, same as the error
  pages; the JSON API stays on its own Lambda.
  `status.public_reliability`
  additionally publishes just the reliability and incidents panels,
  redacted, to signed-out visitors at `/_status/public` — the one part of
  the page with no dependency on the app itself being up. Full detail
  (fields, costs, defaults) is in the `status` variable in
  `variables.tf`.
- `active` — the environment-level sleep switch, see "Environments".

## Environments

Environments live under `terraform/config/stack/`, one directory per environment and
one AWS account per environment: resource names are account-scoped constants,
so two envs in one account would collide. Every env shares the root module in
`terraform/roots/stack`; an env directory holds only `terraform.tfvars` (the
config) and `backend.hcl` (the state location -- bootstrap runs once per
account, and with one account per env each env has its own bucket in its own
account; never point an env at another account's bucket, which would expose
that account's state cross-account). `scripts/tf.sh` wires the two to the
shared root:

```sh
scripts/tf.sh staging init      # once
scripts/tf.sh staging plan
scripts/tf.sh staging apply
```

To create an environment, copy `terraform/config/stack/example` to a new directory,
fill in both files (`account_id` guards against applying with the wrong
credentials), and run init/apply with your `AWS_PROFILE` pointing at that
account. To stage a change before it reaches prod, point the staging env's
`repo_url`/`source_branch` at the feature branch: the builds pull from
whatever the env's tfvars name.

A staging env does not need to run all the time. `active = false` puts it to
sleep: the ASG drops to zero instances and the availability canary and its
alert emails are suspended, while everything stateful (EBS tree data, S3
media, DNS, certificates, ECR images, the last CodeDeploy revision) is
retained. Flip it back and apply, and the replacement instance self-deploys
the last revision -- about five minutes to serving, no other steps. Sleeping
costs a few dollars a month (EIP, EBS, zones); `terraform destroy` remains
the full-teardown option, with the data volume deliberately
`prevent_destroy` so the tree cannot be destroyed by accident.

## Governance: FinOps and SOC2

On top of the workload the stack provisions a thin governance layer. It is
always on (no toggle); the paid detective services (GuardDuty, Config,
Security Hub) are deliberately excluded. Each CMK it provisions runs about
$1/month, and they add up: measured at $8/month total across both accounts
for a `cross_account` backup deployment (7 keys in the workload account, 1 in
the backup account) -- see the per-mode deltas below and in
docs/cross-account-backup.md.

**FinOps.** The existing cost posture (Spot, S3
Intelligent-Tiering + lifecycle, `standard` CPU credits, the `active` sleep
switch) is guarded by:

- an AWS **Budget** (`monthly_budget_usd`, default 50) that emails `alert_email`
  at 80% of actual and 100% of forecasted monthly spend;
- **Cost Anomaly Detection** (per-service) that emails when spend deviates from
  its learned baseline by at least $5; and
- a **Bedrock token alarm** (`llm.hourly_token_alarm`, default 3,000,000) that
  pages a dedicated SNS topic when input+output tokens in a rolling hour cross
  the threshold. The topic is separate (and in the model's invocation region,
  because CloudWatch alarm actions must target a same-region topic); confirm its
  email subscription too, after apply.

The first two are free. They are also *lagging*: Budgets and Anomaly Detection
read billing data that trails real usage by 8–24h, so they cannot catch a
runaway before it has run. The Bedrock alarm exists precisely to cover that gap
for the one unbounded-cost component in the stack — it reads the `AWS/Bedrock`
CloudWatch metrics, which publish within the hour, in the model's invocation
region. Sized in tokens, not dollars (that is what the metric reports); see the
`hourly_token_alarm` note in `variables.tf` for the dollar mapping. Only active
when `llm.enabled`.

Cost-allocation reporting rides on the `Project`/`Env`/`ManagedBy` `default_tags`
every resource carries. In an AWS Organization, cost-allocation tag activation is
owned by the payer/management account and cannot be activated from a linked
account (`aws_ce_cost_allocation_tag` returns `AccessDenied`). Activate the
three keys once in the **payer account's Billing console** (or Terraform run
there); it is not retroactive and takes ~24h to surface as a filter.

**SOC2 (cheap tier).** Audit and detective controls for evidence and exposure
detection:

- a multi-region, management-event **CloudTrail** with log-file validation,
  writing KMS-encrypted objects to a dedicated **Object-Locked** bucket
  (`gramps-web-trail-<account-id>`, GOVERNANCE mode, retention =
  `log_retention_days`). Object Lock is the point: versioning + `prevent_destroy`
  stop overwrites and stop Terraform, but neither stops `s3:DeleteObjectVersion`
  from a compromised admin, and log-file validation is only tamper-*evidence*.
  An Object Lock bucket cannot be a server-access-logging destination, which is
  why the trail and the access logs are two buckets;
- the trail is **wired to detection**, not just archived: a parallel copy goes to
  a CloudWatch Logs group, and metric-filter alarms fire into the audit SNS topic
  on root-account usage, IAM policy changes, and CloudTrail being stopped or
  reconfigured;
- **IAM Access Analyzer** findings are **routed** (EventBridge → SNS): an active
  external-access finding emails a one-line summary instead of sitting in a
  console;
- **S3 server access logging** on the media bucket into the log bucket
  (`gramps-web-logs-<account-id>`, versioned, `prevent_destroy`);
- an **account-level S3 Public Access Block**, the backstop for the per-bucket
  PABs — a bucket created outside Terraform still cannot be made public;
- **TLS-only** (`aws:SecureTransport` deny) on every bucket in the estate —
  media, error pages, web-build cache, trail, logs, pipeline artifacts,
  and the bootstrap state bucket;
- a strict **IAM account password policy** (moot under SSO, kept as
  defense-in-depth).

Confirm the **audit SNS email subscription** after the first apply — the
CloudTrail alarms and Access Analyzer findings deliver through it (separate from
the operational up/down topic).

## Backups and disaster recovery

The irreplaceable data is the EBS data volume (tree DB, search index, users,
secret) and the S3 media bucket (photo/document originals). One AWS Backup plan
covers both, taking a daily recovery point at 03:00 UTC. The `backup` tfvars
object picks where those recovery points also go.

| `mode`         | Recovery points                          | Copies                                              | Setup |
|----------------|------------------------------------------|-----------------------------------------------------|-------|
| `local`        | daily, vault in this account/region      | none                                                | none (default) |
| `cross_region` | + copy to a vault in `region`            | this account, other region                          | none to enter; leaving is manual (see below) |
| `cross_account`| + copy to a vault another org account owns | other account, other region if you point it there | [docs/cross-account-backup.md](docs/cross-account-backup.md) |
| `disabled`     | none                                     | none                                                | — |

`region` defaults to `us-east-2` for the cross modes. `retention_days` (default
7) sets local retention and `remote_retention_days` (default 0 = same) sets the
copies'; the split is deliberate, because local is the fast restore path and the
remote copy is the one that has to still be there after a bad month. Setting
`backup.account_id` and `backup.region` to a separate account and region means
one destination covers both. A failed or expired backup or copy job emails
`alert_email`.

**On-demand, `scripts/backup.sh` covers both shapes of "not at 03:00":**

| | `backup.sh snapshot` | `backup.sh run` |
|---|---|---|
| What | raw EBS snapshot of the volume | AWS Backup job for volume **and** media bucket |
| Consistency | **app-consistent** (stops the writers first) | crash-consistent, like the plan |
| Downtime | ~30-60s | none |
| Off-site | **no**, local only | yes, copied like a scheduled run |
| Expires | **never — delete it yourself** | on the plan's retention |
| Takes | ~1 min | ~30 min (the S3 half is slow) |

`snapshot` is the one to reach for before a risky change you might undo within
the hour — an app upgrade (schema migrations), a bulk import, manual surgery. It
is the only path that quiesces the app, and the only one that leaves something
nobody reaps; `backup.sh status` lists what has accumulated.

`run` is a real recovery point on demand: it seeds the pipeline after a
migration ([docs/cross-account-backup.md](docs/cross-account-backup.md) step 5)
and re-proves the copy path. It does not stop the app, deliberately —
`create-snapshot` closes a point-in-time synchronously, `start-backup-job` only
queues a job and never says when the snapshot's point-in-time closes, so
quiescing for it would mean guessing from undocumented job-state transitions.
Crash-consistency is what the nightly plan and every Spot reclaim already leave
behind, so `run` accepts it and `snapshot` exists for when you cannot.

`run` also encodes the two AWS Backup behaviours that make doing this by hand
unpleasant — `copy_action` fires for plan-driven jobs only, and a job started
without `--lifecycle` never expires — so an on-demand recovery point goes
off-site and expires exactly like a nightly one. The script's header has the
details.

Restoring a snapshot into a volume is [docs/az-move.md](docs/az-move.md) (same or
different AZ/region).

**In-app stored backups** are a quick logical
rollback, not disaster recovery. An owner creates one in the UI and can preview
a restore before applying it, with no volume swap and no downtime; it is the
cheap undo for a session of edits. Each is a tar of the tree export, tree
settings, and user and media records. It omits media files, password hashes
(restored users must reset theirs), OIDC links, custom filters, undo history,
and search indices. Nothing schedules them; the last 5 are kept on the EBS
data volume, so the nightly plan carries them off-site.

**Why `cross_account` is the one that matters.** `cross_region` protects against
a region failure, not against the workload account: source and replica are both
in it. A copy the *destination* account owns, in a vault whose policy grants the
source account nothing but `backup:CopyIntoBackupVault`, is the only copy that
survives losing this account.

**Recovery happens inside the backup account.** AWS Backup cannot restore across
accounts, so you restore the copy where it lives, using the role that account
carries for the purpose. That suits the disaster this guards against — if the
workload account is gone you are rebuilding elsewhere anyway.
`scripts/restore.sh` automates this (and every other restore path, and the
pre-lock drill); its header is the usage text. The path is exercised end to
end by `restore.sh drill`: a copied recovery point restored to a full-size
volume, and a copied S3 recovery point restored to an exact byte match, both
inside the backup account.

Copying a recovery point *back* to the workload account — the tidier answer for
the "account is fine, data is corrupted" case — also works, but is roughly 60x
slower. Rebuilding a brand-new environment from a backup account restore is
`data_volume_snapshot_id` (first apply only). Every path, the restore
parameters, and the timing traps are [docs/restore.md](docs/restore.md) — the
runbook to open when data is actually gone.

**Protecting the backup account.** The vault policy stops the *workload*
account from deleting the copies; SCPs on the backup account (its own OU,
attached once in the Organizations management account) are what stop everyone
else. The SCP list, the `DenyLeaveOrganization` check, and the
`s3:PutLifecycleConfiguration` trap that breaks bootstrap if you get it wrong
are in "Protecting the backup account" in
[docs/cross-account-backup.md](docs/cross-account-backup.md).

**Leaving `cross_region` (or changing `backup.region`) is deliberately not
automatic.** The replica vault and its KMS key carry `prevent_destroy`, so a
plan that would tear them down errors instead of silently destroying the
off-site copy (and scheduling its key for deletion). To genuinely leave: delete
the recovery points, remove the `lifecycle` blocks, then apply.

That guard only covers resources still in the configuration, which is a sharper
limit than it sounds — deleting a resource block deletes its `prevent_destroy`
too, and the plan then destroys happily. Retiring a guarded resource is
therefore always a deliberate two-step (empty it first, then remove it), never
a plain block deletion.

### KMS, and the one key that is not optional

Cross-account copy has exactly one hard encryption prerequisite: the data
volume cannot be on the default `aws/ebs` key, because that key's policy is
immutable and cannot be shared with another account. `modules/storage` gives
the volume its own CMK; a deployment predating that needs a one-time re-key —
see the re-key appendix in [docs/cross-account-backup.md](docs/cross-account-backup.md).

## Layout

Terraform is split three ways, and the distinction is worth internalising
before reading it — the three directories are three different kinds of thing,
not three layers of the same thing:

- `terraform/modules` — **child modules**: building blocks, only ever consumed
  through a `module` block, never applied on their own (network, edge/CloudFront,
  compute + ECR, storage + backup, email/SES, monitoring, `status`, `finops`,
  `audit`, `dns`, `web-build`, `app-pipeline`, `ami-build`).
- `terraform/roots` — **root modules**: the three things you actually apply.
  `stack` composes every module above and is shared by all environments;
  `bootstrap` creates one account's state bucket; `backup-account` holds the
  backup account's vault, key, and the policy granting the workload account
  copy-in and nothing else (see
  [docs/cross-account-backup.md](docs/cross-account-backup.md)).
- `terraform/config` — **no Terraform code at all**: one directory per instance
  of a root, holding just `terraform.tfvars` (config) + `backend.hcl` (state
  location), injected at init/plan time by `scripts/tf.sh`. `config/` mirrors
  `roots/`, so `config/stack/prod` is the prod env, `config/bootstrap/<account>`
  is bootstrap as applied to that account, and so on.
  `config/stack/example/` is the copyable template for a new env.

A root is applied once per directory under its `config/`, and each instance
keeps its own `.terraform` data dir there, so switching instances never needs
`-reconfigure`.

Each build pipeline is one self-contained directory under `build/`, holding its
buildspec, its build script, and its inputs:

- `build/app` — the app image (upstream release + addons) and the CodeDeploy
  bundle. `Dockerfile` + `build.sh` build and push it; this directory is also
  the docker build context. `bundle/` is what CodeDeploy ships to the instance
  (compose file, app config, lifecycle hooks).
- `build/web` — the first-party frontend: a TypeScript + Preact + Vite app
  compiling to a self-contained HTML file per page: the error pages and the
  status shell (`modules/status/lambda/status.py`
  keeps the JSON API). `npm run check` (lint, format, typecheck, unit tests,
  build) is what CI's `web` job and the `gramps-web-frontend` CodeBuild
  project both run. No terraform, no AWS credentials needed to build it
  locally.
- `build/ami` — the base AMI (OS, Docker, agents): the Packer template and the
  units it installs. Rebuilt for patching, not for app version bumps, normally
  via the `gramps-web-ami` CodeBuild project. A rebuild rolls out nothing by
  itself: the deployed AMI is pinned per architecture in tfvars (`ami_ids`), so
  rollout is bump + apply and rollback is reverting the bump.

- `scripts/` — the commands *you* run: `tf.sh` (terraform for one instance of
  one root) and `deploy.sh` (the one command you run to deploy), plus
  `backup.sh`, `azmove.sh`, `clean-amis.sh`, and `media.sh`.
  Nothing in here runs in CI; the build scripts live with their components
  under `build/`. `media.sh` is the one that matters even if you never touch
  the others: Gramps Web has no code path that removes a file from media
  storage, so every deleted or replaced photo leaves its S3 object behind
  forever; `media.sh orphans`/`gc` find and reclaim those.
- `docs/` — deep-dive runbooks referenced above:
  [docs/cross-account-backup.md](docs/cross-account-backup.md),
  [docs/restore.md](docs/restore.md), and [docs/az-move.md](docs/az-move.md).

## Deploying to your own AWS account

1. Fork this repo.
2. Create the state bucket by hand (chicken-and-egg: bootstrap's own state
   lives in it), then let bootstrap adopt and harden it:

   ```sh
   aws s3api create-bucket --bucket <name> --region <region> \
     --create-bucket-configuration LocationConstraint=<region>
   ```

   (us-east-1 only: omit `--create-bucket-configuration`.) Copy an existing
   account's config under `terraform/config/bootstrap/` to a directory named
   for your account and put the account ID, bucket name, and region into both
   files, then:

   ```sh
   scripts/tf.sh bootstrap/<account> init
   scripts/tf.sh bootstrap/<account> import aws_s3_bucket.tfstate_web <name>
   scripts/tf.sh bootstrap/<account> apply
   ```

   The apply layers on versioning, public-access block, the KMS key, and
   default encryption. One bootstrap instance per account, one directory under
   `config/bootstrap/` per account: each env in that account keys its own state
   object in that account's bucket, and an account that needs its own state —
   another env, or the backup account — runs its own bootstrap instance there.
   No `-reconfigure` when switching accounts: each instance has its own data
   dir, and `account_id` in its tfvars makes the wrong `AWS_PROFILE` fail rather
   than build the bucket in the wrong account.

   **If you want `backup.mode = "cross_account"`:** repeat this step for the
   backup account (its own bootstrap instance, its own state bucket), then
   apply the `backup-account` root there too. It is a separate, ordered
   procedure — [docs/cross-account-backup.md](docs/cross-account-backup.md).
3. Create your env from the template: `cp -r terraform/config/stack/example
   terraform/config/stack/prod`, then fill in `terraform.tfvars` (identity, account
   ID, features) and `backend.hcl` (the bucket from step 2 and this env's state
   key; the bucket encrypts state under the CMK step 2 created, so there is no
   key ARN to paste). Everything else has working defaults; instance sizing is
   derived from the feature toggles and admits every eligible Nitro type, with
   `spot_allocation_strategy` choosing the pool (set `instance_requirements`
   only to pin the floor or eligibility), and `spot_enabled = true` is the
   opt-in that trades reclaim outages (median 5 min) for roughly a third of
   the On-Demand price. `rightsize_schedule` is off by default; it only pairs
   with `spot_allocation_strategy = "lowest-price"`, because the watchdog
   replaces the instance to chase the lowest price and would undo a
   capacity-aware allocator's pool choice.
4. Build the base AMIs: `ENV=<env> build/ami/build.sh` (needs Packer on
   your PATH; builds both architectures with the region from your
   tfvars). When it finishes it prints an `ami_ids` block -- paste that into
   your env's `terraform.tfvars`. The first apply needs it; later patch
   rebuilds run in the `gramps-web-ami` CodeBuild project instead (see
   "Deploying").
5. If you enabled the AI assistant (`llm.enabled`): enable Anthropic model
   access in the Bedrock console (Model access, in `primary_region`, or
   `llm.region` if you override it). Only AI chat depends on this; the rest of
   the deploy does not.
6. `scripts/tf.sh prod init`, then `scripts/tf.sh prod apply`. On a fresh domain the apply
   creates the Route53 zones and then waits on ACM certificate validation,
   which cannot complete until the domains' NS records are delegated to those
   zones. While it waits, fetch the NS values (Route53 console, or `aws
   route53 list-hosted-zones-by-name`) and set them at the registrar. If the
   apply times out first, re-running it is safe.
7. Approve the GitHub connection: the `codeconnections_arn` output starts
   PENDING. In the console, Developer Tools > Settings > Connections > update it
   and install the GitHub app on the repo. One connection serves every build
   project.
8. `scripts/deploy.sh gramps`, then `scripts/deploy.sh web`.

The scripts resolve the env from `ENV` (default prod) and the region from
`primary_region` in that env's tfvars (`AWS_REGION` overrides), so nothing
else needs pointing at your region.

## Deploying

```sh
scripts/deploy.sh gramps    # build the image (release + addons) -> ECR -> roll the fleet
scripts/deploy.sh web       # build build/web (error pages + status shell) -> S3 -> invalidate CloudFront
```

Both trigger AWS-side (CodePipeline / CodeBuild) and wait; `ENV=<env>`
targets another environment. Nothing reads Terraform state. To change any
tfvars value: edit, `scripts/tf.sh <env> apply`, then run the matching deploy
command. `deploy.sh web` ships the error pages and the status shell. It is not
gated by a tfvars feature flag (unlike `status`, which needs
`status.enabled = true`), because the error pages it ships are not optional.
On a brand-new stack, run it once after the first `tf.sh apply` — until then
`/_errors/{502,503,504}.html` don't exist and CloudFront serves its own
generic error page instead during an outage, and (when the status page is
enabled) `/_status` 404s the same way until its first `deploy.sh web`.

Base-AMI patching (OS/agents) is its own flow:
`aws codebuild start-build --project-name gramps-web-ami` rebuilds both
architectures and logs an `ami_ids` block; pin it in tfvars and
`scripts/tf.sh <env> apply` to roll the fleet onto the new image (revert the
pin to roll back). A `post_build` step in the CodeBuild project runs
`scripts/clean-amis.sh --delete` after every rebuild, so superseded builds
never strand snapshots; run it by hand for an out-of-band cleanup.

## Testing forks

Every external source this deployment builds from is a tfvars pin, so
carrying a patch or testing a fork is config, not code:

- `repo_url` / `source_branch` — this infra repo itself (buildspecs, scripts,
  the `build/web` frontend, CodeDeploy bundle).
- `gramps_web_repo` / `gramps_web_ref` — a gramps-web frontend fork, built
  over the upstream image's frontend (the release-pinned API is unchanged).
The usual pattern: point a staging env at the fork/branch, apply + deploy
there, then move the same pins into prod's tfvars.

## Serving more beside the app

The edge module's `additional_origins` and `additional_cache_behaviors`
inputs mount any extra content under its own path on the primary
distribution: an S3 origin behind origin access control, plus the behaviors
that route a path pattern to it. Both default to empty, so a deployment that
sets neither carries none of it. The caller owns the origin itself (bucket,
access policy scoped to the `primary_distribution_arn` output, publishing).
Behaviors match in list order ahead of the status behaviors and must not
overlap `/_errors/*` or `/_status*`.

## How a version bump flows

`gramps_web_version` in tfvars -> `terraform apply` updates the build project's
env -> `scripts/deploy.sh gramps` runs the pipeline -> CodeBuild builds a
multi-arch image (deriving the Gramps series and addons-source branch from the
base image), pushes a digest-pinned index to ECR, and emits the CodeDeploy
bundle -> CodeDeploy rolls the instance. Every future Spot replacement pulls the
same pinned digest from ECR.

Addon changes flow the same way (`gramps_addons` -> apply -> `deploy.sh
gramps`).

## Module reference

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.15 |
| aws | >= 6.45 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_metric_alarm.bedrock_tokens](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.instance_refresh_pathological](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_codeconnections_connection.github](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/codeconnections_connection) | resource |
| [aws_s3_account_public_access_block.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_account_public_access_block) | resource |
| [aws_sns_topic.bedrock_alerts](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic) | resource |
| [aws_sns_topic_subscription.bedrock_alerts_email](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_subscription) | resource |
| [aws_ami.base](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ami) | data source |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_route53_zone.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route53_zone) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| alert\_email | Address that receives site DOWN/RECOVERED notices and Spot interruption alerts (string). Confirm the SNS subscription email after the first apply. | `string` | n/a | yes |
| primary\_domain | Canonical apex domain (string). Every other entry in domains, and every www. host, 301s to it. Its Route 53 hosted zone must already exist. | `string` | n/a | yes |
| active | Whether the site runs (bool). False sleeps it: zero instances and no canary alarms, all data kept at a few USD per month; waking takes about five minutes. | `bool` | `true` | no |
| additional\_cache\_behaviors | Extra ordered cache behaviors on the primary distribution (list of objects) that route paths to additional\_origins. See modules/edge/variables.tf for the shape and the paths that must not be overlapped. | ```list(object({ path_pattern = string target_origin_id = string allowed_methods = optional(list(string), ["GET", "HEAD"]) cache_policy_id = optional(string, "658327ea-f89d-4fab-a63d-7e88639e58f6") origin_request_policy_id = optional(string) function_associations = optional(list(object({ event_type = string function_arn = string })), []) }))``` | `[]` | no |
| additional\_origins | Extra CloudFront origins on the primary distribution (map of origin ID to object), for serving content beside the app. See modules/edge/variables.tf for the shape. | ```map(object({ domain_name = string origin_access_control_id = optional(string) }))``` | `{}` | no |
| ami\_ids | Base AMI ID per architecture (map with keys arm64 and x86\_64), or null to use the newest self-owned AMI tagged Name=gramps-web-base. Null rolls a new build out on the next apply; pin to hold it. The AMIs come from the build project this module creates. | `map(string)` | `null` | no |
| api | Non-secret Gramps Web API settings (object). registration is open, unlisted (open endpoint, no sign-up link) or closed. tree\_id is required when tree is not main. Unset (null) fields keep upstream defaults. extra passes other upstream keys without the GRAMPSWEB\_ prefix and is stored in a plain SSM parameter, so never put secrets in it. | ```object({ tree = optional(string, "main") tree_id = optional(string) registration = optional(string, "open") disable_telemetry = optional(bool, false) pillow_max_image_pixels = optional(number) max_thumbnail_file_bytes = optional(number) log_level = optional(string) rate_limit_media_archive = optional(string) cors_origins = optional(string) extra = optional(map(string), {}) })``` | `{}` | no |
| az | Availability zone of the instance and data volume (string), or null for the region's first available zone. Changing it on a live deployment replaces the volume (docs/az-move.md). | `string` | `null` | no |
| backup | AWS Backup of the data volume and media bucket (object), billed per GiB-month of recovery points. mode is local, cross\_region (adds a copy in region, default us-east-2, with a second vault and key), cross\_account (copies into a vault account\_id owns under dest\_vault\_name; docs/cross-account-backup.md), or disabled. retention\_days is in days (0 for remote\_retention\_days means the same as local); schedule is a cron or rate expression in UTC. | ```object({ mode = optional(string, "local") region = optional(string, "") account_id = optional(string, "") retention_days = optional(number, 7) remote_retention_days = optional(number, 0) dest_vault_name = optional(string, "gramps-web-backup-replica") schedule = optional(string, "cron(0 3 * * ? *)") })``` | `{}` | no |
| cpu\_credits | T-instance CPU credit mode (string): standard caps CPU at baseline, unlimited bursts at extra cost. | `string` | `"standard"` | no |
| data\_volume\_gib | Size of the gp3 data volume in GiB (number), billed per GiB-month. Raising it is in place; lowering it is not (scripts/azmove.sh shrink). | `number` | `5` | no |
| data\_volume\_snapshot\_id | EC2 snapshot ID to create the data volume from (string), or null for an empty volume. First apply only: on a live deployment it plans a refused replace (docs/restore.md). | `string` | `null` | no |
| dmarc\_rua | mailto: URI for DMARC aggregate reports (string), or empty to omit the rua tag. | `string` | `""` | no |
| domains | Apex domains served (list of strings), or null to serve only primary\_domain. Each needs an existing public Route 53 hosted zone, such as keel's dns module creates. | `list(string)` | `null` | no |
| env | Environment name (string) that namespaces SSM parameter paths and the CodeDeploy deployment group. Fixed resource names mean one deployment per AWS account. | `string` | `"prod"` | no |
| frontend | Gramps Web browser config, window.grampsjsConfig (object). Empty strings keep the upstream default and omit the key. The map style fields are MapLibre style URLs for the light map, dark map and OpenHistoricalMap overlay. | ```object({ hide_dna_link = optional(bool, false) login_redirect = optional(string, "") map_base_style_light = optional(string, "") map_base_style_dark = optional(string, "") map_ohm_style = optional(string, "") })``` | `{}` | no |
| gramps | Gramps Web build (object). version is the upstream grampsweb image tag; base\_image its repository without a tag; addons are addons-source directory names baked in; web\_repo and web\_ref optionally replace the frontend with a fork build (web\_ref pins a commit); addons\_source\_repo is the addons Git URL. | ```object({ version = optional(string, "26.10.2") base_image = optional(string, "ghcr.io/gramps-project/grampsweb") addons = optional(list(string), []) addons_source_repo = optional(string, "https://github.com/gramps-project/addons-source.git") web_repo = optional(string, "") web_ref = optional(string, "") })``` | `{}` | no |
| instance\_requirements | Override of the ASG instance spec (object), or null to derive sizing from the enabled features. See modules/compute/variables.tf for the shape. | ```object({ vcpu_min = number vcpu_max = optional(number, 2) memory_mib_min = number allowed_types_arm64 = list(string) allowed_types_x86_64 = list(string) })``` | `null` | no |
| llm | AI chat assistant on Bedrock (object); off unless enabled, and billed per token when on. model\_id is the Bedrock model or inference-profile ID without the bedrock: prefix; region is the invocation region (empty for the module's region). max\_requests, max\_tokens and max\_context\_length bound each chat run; system\_prompt overrides the agent prompt. hourly\_token\_alarm is the token count per hour that alarms to alert\_email, 0 to disable. | ```object({ enabled = optional(bool, false) model_id = optional(string, "us.anthropic.claude-haiku-4-5-20251001-v1:0") region = optional(string, "") max_requests = optional(number, 15) max_tokens = optional(number, 200000) max_context_length = optional(number, 50000) system_prompt = optional(string, "") hourly_token_alarm = optional(number, 3000000) })``` | `{}` | no |
| media\_bucket\_name | S3 bucket name for media (string, globally unique), or empty to derive gramps-web-media-<account-id>. | `string` | `""` | no |
| monthly\_budget\_usd | Monthly budget in USD (number) that the status page cost panel compares spend against. Set the alerting budget itself in keel's finops module. | `number` | `50` | no |
| repo\_url | HTTPS GitHub clone URL of the repo the builds pull build/ and scripts/ from (string). Point at a fork to change them. | `string` | `"https://github.com/kjiwa/terraform-aws-gramps-web"` | no |
| rightsize | Scale-back to the cheapest Spot pool (object); off unless schedule is set. schedule is a systemd OnCalendar expression, optionally with a timezone suffix, and applies on the next instance replacement. min\_uptime\_hours is the churn bound between forced replacements. | ```object({ schedule = optional(string) min_uptime_hours = optional(number, 3) })``` | `{}` | no |
| site\_title | Site name shown on error pages (string), or empty to use primary\_domain. | `string` | `""` | no |
| source\_branch | Branch of repo\_url the builds pull (string). | `string` | `"main"` | no |
| spot | Spot capacity (object). enabled runs Spot only at a fraction of the On-Demand price, and each reclaim costs an outage of a few minutes plus an alert email. allocation\_strategy is price-capacity-optimized, capacity-optimized or lowest-price; rightsize needs lowest-price. | ```object({ enabled = optional(bool, false) allocation_strategy = optional(string, "price-capacity-optimized") })``` | `{}` | no |
| status | Operational status page at /\_status (object); off unless enabled. min\_role is the lowest Gramps Web role that may view it (nobody locks it). host\_metrics adds disk and memory panels and a disk alarm, billed per custom metric and alarm per month. volume\_metrics adds exact byte metrics, needs host\_metrics and a base-AMI rebuild. cost adds a Cost Explorer panel at 0.01 USD per call on a Lambda cold start. public\_reliability serves redacted uptime history at /\_status/public and cannot combine with min\_role nobody. | ```object({ enabled = optional(bool, false) min_role = optional(string, "owner") host_metrics = optional(bool, false) volume_metrics = optional(bool, false) cost = optional(bool, false) public_reliability = optional(bool, false) })``` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| ami\_build\_project | AMI CodeBuild project name. Trigger with: aws codebuild start-build --project-name <this>. |
| asg\_name | Auto Scaling Group name. Read by scripts/azmove.sh. |
| backup\_copy\_vault\_arn | Vault each recovery point is copied to (cross\_region: this account, backup region; cross\_account: the backup account). Null when backups stay local or are disabled. Read by scripts/backup.sh run. |
| backup\_vault\_name | Local AWS Backup vault the daily plan writes to; null when backup.mode = disabled. Read by scripts/backup.sh (run and status). |
| codeconnections\_arn | Shared GitHub CodeConnections ARN. Approve once (PENDING -> AVAILABLE) before the first build or pipeline run. |
| ebs\_kms\_key\_arn | CMK ARN encrypting the data volume; null unless backup.mode = cross\_account (the only mode that needs one). Read by scripts/azmove.sh rekey. |
| ebs\_volume\_arn | EBS data volume ARN. Read by scripts/backup.sh run, which passes it to `aws backup start-backup-job --resource-arn`. |
| ebs\_volume\_id | EBS data volume ID. Read by scripts/azmove.sh and scripts/backup.sh snapshot. |
| ecr\_repository\_url | ECR repository the app image is pushed to and pulled from. |
| eip\_public\_ip | EIP public IP. The CloudFront origin address. |
| gramps\_pipeline\_name | App CodePipeline name. Triggered by scripts/deploy.sh gramps. |
| media\_bucket\_arn | S3 media bucket ARN. Read by scripts/backup.sh run, which passes it to `aws backup start-backup-job --resource-arn`. |
| media\_bucket\_name | S3 media bucket name. |
| primary\_distribution\_arn | CloudFront distribution ARN for the primary site. Scope an additional\_origins S3 bucket policy to it. |
| primary\_distribution\_id | CloudFront distribution ID for the primary site (manual invalidations). |
| status\_url | Authenticated operational status page URL (https://<primary\_domain>/\_status). Requires signing in to Gramps Web at a role >= status.min\_role. Null when status.enabled is false. |
<!-- END_TF_DOCS -->
