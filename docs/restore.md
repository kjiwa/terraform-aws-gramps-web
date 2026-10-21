# Restore runbook

Getting the irreplaceable data back: the EBS data volume (tree DB, search index,
users, secret) and the S3 media bucket (photo/document originals).

This is the runbook for when data is lost, corrupted, or the workload account
or region is gone. Building the backup pipeline in the first place is
[cross-account-backup.md](cross-account-backup.md); putting a restored volume
into service afterwards is [az-move.md](az-move.md). Every mechanical step
below is `scripts/restore.sh` — run it with no arguments for the full
subcommand list; this doc covers when to use which and what it does with your
credentials.

## Two accounts, two regions, one placeholder each

Every command below uses `<primary_region>` and `<backup_region>` rather than
a literal region — read them from your own tfvars, not from this page:

| Placeholder | Where to look it up | Holds |
|---|---|---|
| `<primary_region>` | `primary_region` in `terraform/config/stack/<env>/terraform.tfvars` | the local vault, the volume, the media bucket, the subnet |
| `<backup_region>` | `backup.region` in the same file (and `region` in `terraform/config/backup-account/<instance>/terraform.tfvars`, which must match) | the off-site vault |

`scripts/restore.sh` reads both from tfvars itself — these placeholders are for
the raw `aws` commands on this page that it doesn't cover.

Credentials work the same way `scripts/backup.sh` already does: `AWS_PROFILE`
selects the workload account for every script in this repo, `restore.sh`
included. It adds one more: `BACKUP_PROFILE`, for the backup account, needed
by `offsite`, `copy-back`, `drill`, and `drill-cleanup`. There is no
`assume_role` anywhere in this repo — a second account always means a second
profile.

## Where the copies are

| Copy | Lives in | Retention | Speed |
|---|---|---|---|
| Local vault `gramps-web-backup` | workload account, `<primary_region>` | `backup.retention_days` (7, the default) | fast — restore in place |
| Off-site vault (`backup.dest_vault_name`) | backup account, `<backup_region>` | `backup.remote_retention_days` (default 0 = same as local) | restore in that account, or 4-6h to copy back |
| `backup.sh snapshot` output | workload account, snapshots tagged `gramps-data-ondemand` | **none — never expires** | fast |

`scripts/restore.sh list` shows both vaults (the off-site one needs
`BACKUP_PROFILE`). `scripts/backup.sh status` covers the local vault and raw
snapshots only — it deliberately cannot list the off-site vault: that needs the
backup account's own credentials, which is the isolation working as designed.

## Pick a path

| Situation | Do this |
|---|---|
| Bad change in the last few days, account healthy | `restore.sh local` (or a `backup.sh snapshot`, if you took one first) |
| Bad edit session, tree otherwise healthy (`sqlite` only) | Restore an in-app stored backup from the UI. Not DR: see "In-app stored backups" in the README for what it omits |
| Local vault also compromised/corrupted, account healthy | `restore.sh copy-back` — pulls the off-site copy home and restores it (budget hours) |
| Workload account gone or compromised | `restore.sh offsite` — restore where the copy already lives. You are rebuilding elsewhere anyway |
| **Workload *region* gone, account fine** (`cross_account` with a `backup.region` different from `primary_region`) | Same as above: `restore.sh offsite` needs only `BACKUP_PROFILE`, no access to `<primary_region>` at all. See "Region outage" below |
| Rebuilding a fresh/empty environment from scratch (new account, or the original is unrecoverable) | `restore.sh offsite`, then snapshot the result and point a new environment's `data_volume_snapshot_id` at it (see "Rebuilding a fresh environment" below) |
| Volume is fine, just needs a different AZ | Not a restore — [az-move.md](az-move.md) |
| Proving the pipeline works, before locking the vault | `restore.sh drill` — see "Restore drill" below |

**Restoring inside the backup account (`restore.sh offsite`) is the primary
path.** AWS Backup cannot restore across accounts, so a copy in the backup
account is restored where it lives, using the `gramps-web-restore` role that
account carries for the purpose (`terraform/roots/backup-account/iam.tf`).
That suits the disaster this design guards against: if the workload account or
its region is gone, you are standing something up elsewhere regardless.

Exercised end to end by `restore.sh drill`: a copied recovery point restored
to a full-size volume, and a copied S3 recovery point restored to an exact
byte match, both inside the backup account.

## Region outage

Under `backup.mode = "cross_account"`, the destination vault's ARN is built
from `backup.region`, not `primary_region`
(`modules/storage/backup.tf`) — so as long as your deployment sets
`backup.region` to a region different from `primary_region` (check your own
tfvars; there is no repo-wide default this doc can promise), every off-site
copy already sits outside a `<primary_region>` outage, not just outside the
workload account. `restore.sh offsite` only ever touches `BACKUP_PROFILE` and
`<backup_region>` — it needs no working `<primary_region>` and no workload
credentials at all.

What a region outage *does* take out is your ability to run `terraform apply`
against the workload stack, if its state bucket lives in `<primary_region>`
too (`terraform/config/stack/<env>/backend.hcl` — check yours). The backup
account's own state, vault, key, and restore role are wherever *its* tfvars
put them, independent of the workload's region choice. Rebuilding during an
outage is the same shape as any disaster rebuild: `restore.sh offsite`,
snapshot the result, bootstrap a state bucket somewhere that's still up, and
apply a fresh environment there (see "Rebuilding a fresh environment" below).
State itself is reconstructible (`terraform import`); the volume and the media
corpus are not, and both are already safe outside the region that just went
down.

## Restore drill

`restore.sh drill` is the "restore drill"
[cross-account-backup.md](cross-account-backup.md) requires before locking the
destination vault, automated: it seeds a fresh recovery point for both the
volume and the media bucket, copies each off-site, confirms they landed (from
the backup account's own credentials), restores both to scratch resources
inside the backup account — verifying the S3 copy byte-for-byte against the
live media bucket's object count and total size — and runs the negative test
(the workload account must get `AccessDeniedException` trying to delete from
the destination vault). Requires `backup.mode = "cross_account"` and
`BACKUP_PROFILE`; refuses to run against an already-locked vault.

```sh
export AWS_PROFILE=<workload-account-admin>
export BACKUP_PROFILE=<backup-account-admin>
scripts/restore.sh drill
```

The EBS half is checked by size only — a restored volume reporting a positive
number of GiB, since an empty recovery point restores `COMPLETED` too, but
that message alone doesn't prove the *contents* match. Full byte-for-byte
verification of the volume is a manual exercise (attach the restored volume to
an instance you already have and `sha256sum` diff it), not something the drill
automates: the backup account deliberately has no VPC or compute of its own
(`terraform/roots/backup-account/` provisions a vault, a key, and an IAM role —
nothing else), so proving EBS contents needs a scratch instance stood up for
the purpose. The S3 half needs none of that, which is why it's the one the
drill checks unconditionally.

**Run `restore.sh drill-cleanup` before locking the vault — and before
attaching the protective SCPs from "Protecting the backup account" in
[cross-account-backup.md](cross-account-backup.md).** The drill creates real
recovery points and real scratch resources, and that SCP's
`DeleteRecoveryPoint` deny blocks removing them regardless of whether the
vault itself is locked yet. `drill` prints this reminder and a manifest path
(`scripts/restore-drill-<ts>.json`, `.gitignore`d — it's a partial record of
what the drill touched); `drill-cleanup` reads that manifest and deletes each
artifact, retrying only what's still outstanding if you run it again:

```sh
scripts/restore.sh drill-cleanup
```

If a delete attempt comes back denied by an SCP, that's the scenario above,
not a bug — see "Protecting the backup account" for what that means and what
to do about it. Every drill artifact is seeded with a short, fixed retention
for exactly this reason, so a stuck one expires on its own within a day either
way.

Only after cleanup confirms clean (`scripts/restore.sh list` shows nothing
left over) is it safe to lock the vault — see "Verify, then lock" in
[cross-account-backup.md](cross-account-backup.md).

## Restore inside the backup account

```sh
export AWS_PROFILE=<backup-account-admin>
scripts/restore.sh list
```

`restore.sh offsite <recovery-point-arn>` restores it where it lives, using
the `restore_role_arn` output of the `backup-account` root
(`terraform/roots/backup-account/iam.tf`). EBS lands as a scratch volume,
tagged `Name=gramps-data-restored`; S3 lands in a scratch bucket the script
creates for you (versioned, as an S3 restore requires — see below), or pass
`--to-bucket <name>` to reuse one of your own. Neither is meant to run
long-term; the script prints the exact cleanup command for the volume, and
`drill-cleanup` removes what a drill created.

The scratch bucket is one stable `gramps-web-restore-<account-id>-<region>`
per account and region, never deleted: the protective SCPs (see "Protecting
the backup account" in [cross-account-backup.md](cross-account-backup.md))
deny `s3:DeleteBucket` and `s3:DeleteObjectVersion` account-wide. A lifecycle
rule applied on every run expires objects, noncurrent versions, delete markers,
and incomplete multipart uploads after a day, so the bucket empties itself
within a few days. S3 restores skip keys that already exist, so the script
refuses to start while the bucket still holds anything; wait for expiry, or pass
`--to-bucket` with an empty versioned bucket.

### Restore parameters are not guessable — ask first

`restore.sh` resolves these for you; this is what it's doing, useful if you
ever need to do it by hand:

```sh
aws backup get-recovery-point-restore-metadata --region <region> \
  --backup-vault-name <vault> --recovery-point-arn <rp-arn> --query 'RestoreMetadata'
```

**S3.** Mandatory metadata is `DestinationBucketName`; useful optionals are
`RestoreACLs`, `EncryptionType` (`original` | `SSE-S3` | `SSE-KMS`), and
`RestoreLatestVersionsUpTo`. There is no prefix key — restore to a scratch
**bucket**, which **must have versioning enabled** (the job fails outright
otherwise) and must not already hold the objects: restores skip existing keys,
so restoring over the source reports success having done nothing.
`restore.sh` never targets the live bucket for exactly this reason.

If the recovery point were empty the job returns `COMPLETED` with *"There are no
objects that match the restore request"* — that message, not the job state, is
the empty-backup signal.

**EBS.** `availabilityZone` comes back null; `restore.sh` passes it explicitly
along with `volumeType`, `volumeSize`, `encrypted`, and `kmsKeyId`. Restored
volumes are scratch — never attach one to the live instance. To put a restored
volume into service in the workload account, see [az-move.md](az-move.md)
(`adopt`).

**Anything restored into the media bucket lands as SSE-S3**, not under the media
CMK — the bucket's default encryption governs new writes only. That is hygiene,
not a backup problem. Re-encrypt in place if you want the corpus uniformly
CMK-backed:

```sh
aws s3 cp s3://<media-bucket> s3://<media-bucket> \
  --recursive --metadata-directive REPLACE \
  --sse aws:kms --sse-kms-key-id <media-cmk-arn>
```

Idempotent; safe to re-run.

### Rebuilding a fresh environment from a restored volume

`data_volume_snapshot_id` (`variables.tf`) creates the
data volume from an EC2 **snapshot** ID at first apply — the disaster-rebuild
path for a brand-new environment, not a live one (see
`modules/storage/main.tf` for why a live environment can't use this
to "restore"). **That's what [az-move.md](az-move.md) is for.**

`restore.sh offsite` produces a *volume*, not a snapshot, so to feed
`data_volume_snapshot_id` take one more step after restoring and verifying:
snapshot the restored volume, then apply the new environment pointed at it —
in the backup account itself, or after copying/sharing the snapshot into
whichever account the rebuild targets.

```sh
aws ec2 create-snapshot --region <backup_region> --volume-id <restored-vol-id> \
  --description "disaster rebuild source" \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Project,Value=gramps-web},{Key=Name,Value=gramps-data-rebuild}]'
```

Then, in the new environment's tfvars:

```hcl
data_volume_snapshot_id = "snap-..."
```

The restored volume's AZ does not need to match anything at this point —
snapshots are region-scoped, not AZ-scoped, and `modules/network`
picks (or you pin, via `az`) whatever AZ the new environment's subnet lands
in. `modules/compute`'s `AttachVolume` IAM grant is scoped to the
*new* volume's ARN once Terraform creates it, so no manual tagging is needed
on this path (unlike `restore.sh local`/`copy-back`, which tag the volume
themselves for exactly this reason) — the resulting volume is created and
tagged by Terraform itself.

The media bucket has no equivalent variable: an S3 restore writes into a
bucket that already exists, so that half of a rebuild is apply first, then
`restore.sh` into the new bucket.

## Copying back to the workload account: works, but budget hours

If you would rather recover *into* the workload account, `restore.sh
copy-back <recovery-point-arn>` does both halves in one command: pulls the
off-site recovery point back into the local vault, then restores it using the
same `gramps-web-backup` role the daily plan uses. It is enabled by
`aws_backup_vault_policy.this` in `modules/storage/backup.tf` (the workload
vault accepting copies) and the symmetric KMS grant on its vault key.

```sh
export AWS_PROFILE=<workload-account-admin>
export BACKUP_PROFILE=<backup-account-admin>
scripts/restore.sh copy-back <recovery-point-arn>
```

**It is roughly 60x slower than the outbound direction, and that is the whole
trap.** Measured on this design:

| Direction | Duration |
|---|---|
| workload -> backup | a few minutes |
| backup -> workload | **4-6 hours** |

The job sits in `CREATED` — not `RUNNING` — for essentially all of it, with no
status message and no sign of progress of any kind. It is indistinguishable
from hung. `restore.sh copy-back` says so before it starts and polls to
completion either way, so once it's running there's nothing to babysit.
Errors are just as slow — a copy job with a role that doesn't exist can take
hours to report the failure.

Consequences worth planning around:

- **Do not conclude anything from a short poll.** Chasing SCPs, KMS grants, or
  service-linked roles instead wastes an afternoon on causes that aren't real.
- **Do not delete the destination vault while a job is queued.** A queued copy
  job targeting a vault that gets cleaned up in the meantime fails hours later
  with `Could not find backup vault`.
- If you need the data sooner than that, `restore.sh offsite` and move the
  contents by hand — an EBS volume beats waiting six hours.

## If a copy job failed

`FAILED`, or `Failed to unshare snapshot`, means a key grant is wrong. Start
with the volume key's `BackupAccountCopySnapshot` and `BackupAccountCreateGrant`
statements (`modules/storage/main.tf`) and the local vault key's cross-account
grant (`modules/storage/backup.tf`). Every KMS grant in this design fails at
**runtime**, not plan time — a plan proves nothing here.

## After a restore

- Verify the site loads and the tree data is intact.
- Keep the pre-restore volume for a few days as a rollback before deleting it.
- Re-prove the pipeline still works: `scripts/backup.sh run "post-restore check"`.
