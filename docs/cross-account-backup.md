# Cross-account backup

Copying the irreplaceable data — the EBS data volume and the S3 media bucket —
to a vault **a different AWS account owns**: one the workload account cannot
reach into and delete backups from, whatever happens to its own credentials.

This is the runbook for building the pipeline, whether that is a brand-new
deployment's first apply or an existing `local`/`cross_region` deployment
adopting it later — the [appendix](#appendix-migrating-an-existing-deployment)
covers what only the latter needs. It is ordered and gated either way: do not
lock the destination vault until step 6 proves the copy pipeline end to end —
locking a vault whose backups you have not verified can leave you paying to
store recovery points you cannot delete.

Placeholders recur throughout: `<root>` is the Terraform root that
instantiates this module in the workload account, and `<backup-root>` the one
for the backup account. `<region>` is the workload module's region and
`<backup_region>` is `backup.region` (the region of the backup account's own
provider, which must match). See [restore.md](restore.md) for the placeholder
table and why the design never assumes a specific region for either. The
scripts take the workload root as `--root <root>`, or `GRAMPS_WEB_ROOT`.

## Why bother

`local` and `cross_region` both leave every copy owned by the workload
account. `cross_region` protects against a region failure — it does nothing
against the account itself: a compromised credential, a hijacked root user, or
an account-closure mistake reaches the replica exactly as easily as the
original, because both live under the same account's keys and the same
account's delete permissions.

A copy that the destination account owns, in a vault whose policy grants the
source account nothing but `backup:CopyIntoBackupVault`, survives all of that.

## What it costs

About **+$3/month** over `local` mode, almost entirely KMS keys at ~$1 each
(destination vault key, volume key, backup-account state key; the local
vault's key exists in every mode). Storage stays in cents: cross-account
copies are incremental after the first full copy, and AWS Backup prices EBS
recovery points the same as plain snapshots.

## Prerequisites

- `aws`, `terraform`, `jq`.
- A workload root that exports the module as an output
  (`output "gramps_web" { value = module.gramps_web }`), which the scripts read.
- Admin credentials for **three** accounts: the Organizations management
  account, the workload account, and the backup account.
- The backup account must already exist and be in the **same organization** as
  the workload account. AWS Backup cross-account copy is org-only; there is no
  cross-org path, and this is the reason the design does not offer one.

## 1. Management account: enable cross-account backup (MANUAL — blocker)

Nothing else in this runbook works until this is done, and only the
Organizations *management* account can do it. In the management account's
Terraform project:

```hcl
resource "aws_backup_global_settings" "this" {
  global_settings = {
    isCrossAccountBackupEnabled = "true"
  }
}
```

Verify:

```sh
AWS_PROFILE=<mgmt> aws backup describe-global-settings
```

While you are in this project, also put the backup account in its own OU and
attach the `ProtectBackups` and `DenyLeaveOrganization` SCPs. Neither is
required to make copies work; both are what make the copies worth having, and
step 2 below depends on getting the `s3:PutLifecycleConfiguration` detail
right.

### Protecting the backup account

The vault policy stops the *workload* account from deleting the copies; SCPs
on the backup account are what stop everyone else, and they are set once in
the Organizations management account, not here.

Put the backup account in **its own OU**, not the workload OU: an SCP scoped to
an OU containing both accounts cannot protect the backup account *differently*
from the account it exists to protect against, which is the entire point. Then
deny, on that OU (the `ProtectBackups` SCP):

| Action | Closes |
|---|---|
| `backup:DeleteBackupVault` | deleting the vault outright |
| `backup:DeleteRecoveryPoint` | deleting individual copies |
| `backup:DeleteBackupVaultLockConfiguration` | unlocking the vault, then deleting |
| `backup:UpdateRecoveryPointLifecycle` | shortening retention so AWS expires the copies for you |
| `kms:ScheduleKeyDeletion`, `kms:DisableKey` | crypto-shredding the vault's key |

The last two `backup:` entries are the ones that are easy to miss, and without
them the first two are theatre — an attacker who can unlock the vault or set
retention to a day does not need `DeleteRecoveryPoint`. This is also what makes
the vault's *governance*-mode lock as strong as compliance mode without the
irreversibility: the lock cannot be removed from inside the backup account at
all, because the SCP denies it to every principal there, this account's admin
included. Reversing it takes two accounts.

Also confirm a **`DenyLeaveOrganization`** SCP covers the backup account — AWS
calls this out specifically: a destination account that leaves the organization
*keeps the backups*. Attached at the root it inherits down, which counts; check
the targets rather than assuming:

```sh
AWS_PROFILE=<mgmt> aws organizations list-targets-for-policy --policy-id <scp-id>
```

**Do not deny `s3:PutLifecycleConfiguration` on that OU.** It looks like it
belongs and it breaks the state bucket module and `restore.sh`: the backup
account's Terraform state bucket has a lifecycle config keel's `state-bucket`
module manages, and the restore scratch bucket empties itself by one. It guards
nothing — AWS Backup keeps S3 recovery points in AWS-managed vault storage, so no
backup data lives in an S3 bucket there at all. If you want the S3 denies anyway,
scope them with `NotResource` on the state and scratch buckets.

None of this touches the copy pipeline: SCPs do not apply to service-linked
roles, and the copy into the vault is executed by the backup account's
`AWSServiceRoleForBackup`. Keep the *source* account's OU free of these denies
though — it needs `backup:CopyFromBackupVault` and `CopyIntoBackupVault`.

## 2. Backup account: state bucket

The backup account needs its own Terraform state, in its own account —
pointing it at the workload account's bucket would hand the backup account's
role the workload account's state *and* make the backup account's state
deletable from the workload account, inverting the isolation.
keel's `state-bucket` module runs once per account for exactly this reason.

**If the Backup OU's SCP denies `s3:PutLifecycleConfiguration`, this step fails**
with AccessDenied on `aws_s3_bucket_lifecycle_configuration.tfstate_web`, and it
will fail again on every later apply — so applying before attaching the SCP is
not a workaround. Fix the SCP instead. An SCP protecting backup data has no
reason to reach the state bucket: AWS Backup keeps S3 recovery points in
AWS-managed vault storage, so **the backup account holds no backup data in S3 at
all**, and the only buckets in it are the state bucket and `restore.sh`'s scratch bucket. Either drop the action or
scope the statement with `NotResource` on the state and scratch buckets.

In `<backup-root>`, a root with its own AWS provider for the backup account
(pin `allowed_account_ids` to it, so the wrong `AWS_PROFILE` fails instead of
building this account's bucket somewhere else):

```hcl
module "state" {
  source      = "git::https://github.com/kjiwa/terraform-aws-keel.git//modules/state-bucket?ref=v0.1.0"
  bucket_name = "<state-bucket>"
}
```

Create the bucket by hand (chicken-and-egg: the module manages the bucket its
own state lives in), point a partial `backend "s3" {}` at it, then import and
apply:

```sh
export AWS_PROFILE=<backup-account-admin>
aws s3api create-bucket --bucket <state-bucket> --region <backup_region> \
  --create-bucket-configuration LocationConstraint=<backup_region>

terraform -chdir=<backup-root> init -backend-config=backend.hcl
terraform -chdir=<backup-root> import module.state.aws_s3_bucket.tfstate_web <state-bucket>
terraform -chdir=<backup-root> apply
```

Leave `encrypt` and `kms_key_id` out of the backend configuration: they would
override the bucket's default encryption. Keep one `TF_DATA_DIR` per root, or
pass `-reconfigure` when switching between the workload and backup roots, so
the backend binding does not follow whoever ran `init` last.

## 3. Backup account: vault + key

Add keel's `backup-vault-account` module to `<backup-root>`:

```hcl
module "backup_vault" {
  source = "git::https://github.com/kjiwa/terraform-aws-keel.git//modules/backup-vault-account?ref=v0.1.0"

  name_prefix                   = "gramps-web"
  vault_name                    = "gramps-web-backup-replica"
  source_account_id             = "<workload-account-id>"
  s3_recovery_enabled           = true
  vault_reader_source_role_name = "gramps-web-status"
}
```

```sh
export AWS_PROFILE=<backup-account-admin>
terraform -chdir=<backup-root> apply
```

`name_prefix` must be `gramps-web`: `scripts/restore.sh` and the status page
address the restore and vault-reader roles by that name. Creates the vault, its CMK (mandatory — a cross-account destination cannot be
the default vault, because the AWS-managed `aws/backup` key has an immutable
policy that cannot be shared), and the vault policy granting the workload
account `backup:CopyIntoBackupVault` and nothing else.

**Leave `vault_lock.mode` at `"none"` (the default) initially.** Locking a vault whose copy pipeline
has not been proven can leave you paying to store recovery points you cannot
delete — and with the Backup OU's SCP in place, "cannot delete" is close to
literal (see step 6). Step 6 turns it on, after the pipeline works.

`vault_name` here and `backup.dest_vault_name` on the workload module are
a contract: the workload stack *constructs* the destination vault's ARN from
account + region + name rather than having one pasted in. A mismatch is a
runtime copy-job failure, not a plan error.

## 4. Workload account: set the mode and apply

Set `backup` on the module in `<root>`:

```hcl
module "gramps_web" {
  # ...
  backup = {
    mode                  = "cross_account"
    account_id            = "<backup-account-id>"
    region                = "<backup_region>"
    retention_days        = 7
    remote_retention_days = 30
  }
}
```

Point `region` at a region other than the workload's primary and this
**subsumes** `cross_region` rather than sitting beside it: one destination,
different account *and* different region.

`account_id` + `region` + `dest_vault_name` are what the stack constructs the
destination vault's ARN from, so they must match step 3's apply exactly.

On a **fresh deployment** — no volume yet, or one that has never carried this
mode — this is the whole step. Apply normally:

```sh
terraform -chdir=<root> apply
terraform -chdir=<root> output -json gramps_web | jq -r .backup_copy_vault_arn
```

`modules/storage` creates the data volume directly on the CMK `cross_account`
requires, so there is nothing to re-key. **If you are adding this mode to a
deployment whose volume already exists**, check it first:

```sh
aws ec2 describe-volumes --volume-ids <vol-id> --query 'Volumes[0].KmsKeyId'
```

A volume already on a customer-managed key needs nothing further either. One
still on the AWS-managed `aws/ebs` key cannot be backed up cross-account by any
mechanism — that key's policy is immutable and unshareable — and needs the
re-key procedure in the [appendix](#re-key-the-data-volume-site-goes-down)
*before* this apply will succeed. `plan` errors on the volume's
`prevent_destroy` until then, which is the design working, not a bug.

## 5. Seed the first recovery points

`copy_action` only fires for plan-driven jobs, so do not wait until 03:00 to
find out whether any of this works. Back up every resource now and copy them
across:

```sh
export AWS_PROFILE=<workload-admin>
scripts/backup.sh --root <root> run "seed cross-account pipeline"
```

Use the workload account's **admin** profile: reading Terraform outputs decrypts
state, which ReadOnly cannot do. The script checks the account up front, because
the failure otherwise arrives much later as a baffling `AccessDeniedException`
from `start-backup-job` rather than anything about credentials.

`run` does the whole sequence — backup job for the data volume and the media
bucket, wait, then a copy job per
recovery point — and encodes the three traps that made doing it by hand
unpleasant:

- **`start-copy-job` takes no `--resource-arn`.** The recovery point ARN already
  identifies the resource; passing one (as `start-backup-job` requires) is an
  "Unknown options" error.
- **Both job types need `--lifecycle`.** Without it the recovery point never
  expires — silently permanent in the local vault, and rejected outright by the
  destination once step 6 locks it. `run` reads the retention off the live plan,
  so a seeded point expires exactly like a nightly one.
- **The S3 job takes 20-30 minutes** even at this size, sitting at
  `PercentDone: 0.0` for most of it: AWS Backup's S3 jobs are dominated by fixed
  per-job setup, not by data, and the percentage jumps near the end rather than
  climbing. That is not a hang, and `run` says so while it waits.

Check it landed with `scripts/backup.sh --root <root> status`, which shows recent backup jobs,
recent copy jobs, and what is in the local vault. It cannot show the far side —
listing the destination vault needs the destination account's credentials, which
is the isolation working as designed; step 6's drill does that.

The first backup of every resource is a **full** backup, so the migration needs
no backfill step at all.

**The S3 recovery point will report `BackupSizeInBytes: 0`.** That is a known AWS
reporting behaviour for S3 recovery points, not an empty backup — AWS does not
populate a meaningful size for them, and Cost Explorer is the way to see real
backup storage. Do not chase it; the restore drill in step 6 is what actually
proves the objects are in there.

## 6. Verify, then lock (MANUAL — do not skip)

A plan proves nothing here. Every KMS grant in this design fails at **runtime**,
not plan time, and a cross-account misconfiguration looks exactly like success
until the copy job runs.

```sh
export AWS_PROFILE=<workload-admin>
export BACKUP_PROFILE=<backup-account-admin>
scripts/restore.sh --root <root> drill
```

The drill seeds a fresh recovery point for every resource type (the data
volume plus S3), copies each
off-site, confirms landing from the backup account's own credentials, restores
all of it into the backup account (verifying the S3 half byte-for-byte against
the live media bucket), and runs the negative test — the workload account must get
`AccessDeniedException` trying to delete from the destination vault. It refuses
to run against an already-locked vault, which is why this has to happen before
locking rather than after. See "Restore drill" in [restore.md](restore.md) for
what each phase proves.

**Run `scripts/restore.sh --root <root> drill-cleanup` before locking the vault — and before
attaching the protective SCPs from "Protecting the backup account" above.** The
drill creates real recovery points and scratch resources, and `DeleteRecoveryPoint`'s
SCP deny blocks removing them regardless of whether the vault itself is locked
yet. `drill` prints this reminder and a manifest path when it passes;
`drill-cleanup` reads that manifest and removes each artifact, retrying only
what is still outstanding if you run it again. Confirm clean with
`scripts/restore.sh --root <root> list`.

Once cleanup confirms clean, set `vault_lock = { mode = "governance" }` on the
`backup_vault` module in `<backup-root>` and apply it in the backup account. The status page's backups panel reads the lock state
live, so it reflects the change on its own -- no workload-side apply needed.

Governance, not compliance — and with the Backup OU's SCP that is a stronger
control than the AWS docs make it sound. The docs describe governance as
unlockable by a sufficiently privileged principal in the vault's own account,
which would make it thin protection against exactly the attacker you care about.
`ProtectBackups` denies `backup:DeleteBackupVaultLockConfiguration` to *every*
principal in the OU, this account's admin included, so the lock cannot be removed
from inside this account at all. Reversing it takes two accounts: detach the SCP
from the management account, then delete the lock here.

That combination is the whole reason compliance mode is unnecessary. You get its
protection — no single compromised principal can unlock the vault, shorten
retention via `UpdateRecoveryPointLifecycle`, or delete a recovery point —
without its irreversibility. Compliance would add only the property that nobody,
including you, can ever undo it before retention expires, while you keep paying
to store everything. On a personal deployment that trade is not worth it.

Practical consequence, so it does not read as a bug later: setting `vault_lock.mode`
back to `"none"` will fail with AccessDenied until the SCP is detached.

## Appendix: migrating an existing deployment

Skip this whole appendix if you are deploying fresh, or if `aws ec2
describe-volumes` already shows the data volume's `KmsKeyId` set to a
customer-managed key — step 4 above covers everything you need.

### Re-key the data volume (site goes down)

A volume created with `encrypted = true` and no `kms_key_id` is on the
AWS-managed `aws/ebs` key, whose policy is immutable and **cannot be shared with
another account**. AWS will not copy a snapshot the destination account cannot
decrypt, so such a volume cannot be backed up cross-account by any mechanism.
There is no re-key-in-place API; the volume must be replaced, and it is
`prevent_destroy`, so this cannot be an ordinary apply.

Set `backup.mode = "cross_account"` on the module first (step 4 above), but **do not
apply yet** — the key only exists in `cross_account` mode (it is dead weight in
the others), and applying with the mode set but the volume not yet re-keyed is
exactly the sequencing this needs. `plan` errors until the volume is re-keyed —
that is the design working, not a bug:

```
Error: Instance cannot be destroyed
  Resource module.gramps_web.module.storage.aws_ebs_volume.this has lifecycle.prevent_destroy
```

Create the key, and nothing else:

```sh
export AWS_PROFILE=<workload-admin>
terraform -chdir=<root> apply -target=module.gramps_web.module.storage.aws_kms_key.data
```

Then snapshot, re-encrypt, restore, adopt. `rekey` defaults to the key the stack
declares; pass the ARN explicitly if the targeted apply left the output unset:

```sh
scripts/azmove.sh --root <root> rekey
# or: scripts/azmove.sh --root <root> rekey "$(aws kms describe-key --key-id alias/gramps-data \
#       --query KeyMetadata.Arn --output text)"
# -> prints the new volume id
scripts/azmove.sh --root <root> adopt <new-vol-id> <same-az>
```

**Review the plan by hand. Do not skip this.**

```sh
terraform -chdir=<root> plan
```

The data volume must now be a **no-op** — that is the whole point of the adopt.
If it still shows destroy or replace, stop: the adopt did not take, and applying
would try to delete your only copy. `azmove.sh adopt` wrote a state backup to
`azmove-state-<ts>.json` in the current directory; `terraform state push -force` it back (`-force`: the adopt's
`state rm` raised the serial, so the backup's is older).

Everything else in that plan should be the cross-account wiring itself: the
volume adopting the new key, the cross-account statements added to the vault
key, the vault policy accepting copy-backs, and the copy_action added to the
plan. Coming from `cross_region`, the plan also wants to destroy the replica
vault and its key, and their `prevent_destroy` makes it error instead —
[below](#decommission-the-cross_region-replica-vault) is the deliberate way
through, and it has a continuity-preserving option.

Then apply and bring the site up. Apply must precede scale-up: the
`AttachVolume` IAM policy is scoped to the volume ARN, so until it is applied a
launching instance is denied the attach.

```sh
terraform -chdir=<root> apply
scripts/azmove.sh --root <root> finish https://<your-domain>/
```

The old volume is untouched and is your rollback. Do not delete it yet ([Clean
up](#clean-up-days-later)). Continue at step 5 above to seed the pipeline.

### Decommission the cross_region replica vault

Only relevant if you are migrating from `cross_region`, and only once step 6
above has passed with the new pipeline. Switching `backup.mode` away from
`cross_region` drops `aws_backup_vault.replica` and `aws_kms_key.backup_replica`
to count 0. Both carry `prevent_destroy`, so the plan errors instead of
silently destroying the off-site copy (and scheduling its key for deletion):

```
Error: Instance cannot be destroyed
  Resource module.gramps_web.module.storage.aws_backup_vault.replica has lifecycle.prevent_destroy
```

Two ways through:

**(a) Continuity-preserving.** Before re-keying and applying above, add
`removed` blocks for both resources with `lifecycle { destroy = false }` — this
drops them from Terraform's management without touching the running vault or
key, so the old off-site copy survives untouched through the whole migration.
Once step 6 passes, retire them by hand: delete the vault's recovery points,
delete the vault, schedule the key for deletion (a 30-day pending window —
`cancel-key-deletion` reverses it any time before then), then delete the
alias.

**(b) Simple**, if a window with no off-site copy is acceptable: delete the
replica vault's recovery points, remove the two `prevent_destroy` blocks in
`modules/storage/backup.tf` (this needs a fork or a local checkout of the
module), then let the next apply destroy the vault and key outright.

Either way, confirm you are touching the *replica* key: the state bucket's CMK
also lives in the backup region and must not be scheduled for deletion.

### Clean up (days later)

- Delete the pre-re-key volume: `aws ec2 delete-volume --volume-id <old-vol>`.
- Delete the snapshots `azmove.sh rekey` left behind (`gramps-data-azmove`,
  `gramps-data-rekey`).

### Rollback

- **Before re-keying's apply**: nothing has changed. `terraform state push -force`
  the state backup `azmove.sh adopt` wrote, then delete the restored volume.
- **After re-keying, before decommissioning the replica vault**: revert the
  `backup` setting to its previous mode; adopt the old volume back if you
  also want to undo the re-key. Migrants who used the continuity-preserving
  option can `terraform import` the replica vault and key back into state.
- **After decommissioning the replica vault**: recovery is from the backup
  account's vault: restore **inside** that account (step 6), or copy a
  recovery point back here and restore it — that works, but budget 4-6 hours
  ([restore.md](restore.md)).

## What "removing the local backup" would mean

It is not available, and the reason is structural rather than a policy choice:
`copy_action` copies **from** a local recovery point, so AWS Backup cannot write
straight to another account. What is tunable is retention —
`backup.retention_days` for the local vault against
`backup.remote_retention_days` for the copies.

You want the local copy anyway. It is the fast restore path; recovering from
the backup account means copying back first. The only thing this migration can
retire is the **same-account cross-region** copy
([above](#decommission-the-cross_region-replica-vault), `cross_region`
migrants only), never the local one.
