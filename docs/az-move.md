# AZ move runbook

Moving the data volume, public subnet, and instance to a different availability
zone. Use this when the pinned AZ is durably impaired (extended Spot stockout
across your whole instance set, or an AZ-level service problem). You normally
don't need it: a short Spot gap clears on its own.

`azmove.sh` automates the mechanical work and stops at the points where you must
decide or review. It never lets Terraform destroy the data, and your original
volume survives the whole move as a fallback.

## Why this is fiddly

The volume and subnet are AZ-pinned, and AZ is immutable on both — Terraform
can only change it by replacing the resource. The volume also has
`prevent_destroy`, which (correctly) blocks Terraform from destroying your only
copy. So the move is: snapshot the live volume, restore it into the new AZ
out-of-band, swap that volume into Terraform state, then apply the subnet and
instance change. The original volume is only removed from state (not deleted),
so it stays in AWS until you delete it by hand.

What is *not* AZ-bound and needs no attention: the EIP, S3 buckets, SES, DNS,
CloudFront, and all IAM.

## Prerequisites

- `aws`, `terraform`, `jq`, `curl` on PATH; credentials for the env's account.
- The stack is applied and `scripts/tf.sh <env> output` works.
- Run from the repo root or invoke by path. `ENV` selects the environment
  (default prod). Region comes from `primary_region` in `terraform.tfvars`
  (`AWS_REGION` overrides). State backups land in `scripts/` as
  `scripts/azmove-state-<ts>.json` (matching `.gitignore`).

## Step 1 — choose the AZ (manual)

```sh
./scripts/azmove.sh score
```

Prints the Spot placement score (1–10, higher is better) per AZ for the
instance types your ASG allows (read live from its mixed-instances policy). Pick the highest. The score is account- and time-specific
and is a likelihood, not a guarantee — it informs the choice, it doesn't make
it. Override the type list with `INSTANCE_TYPES="t4g.large m6g.large ..."` if
you want to score a different set.

## Step 2 — prepare (automated; takes the site down)

```sh
./scripts/azmove.sh prepare <az>
```

Scales the ASG to 0 (the site goes down and the volume detaches), snapshots the
quiesced volume, and restores a new gp3 volume from that snapshot in the target
AZ — tagged `Project=gramps-web` (required, or the instance role can't attach
it) and `Persistent=true` (documents which volume is the irreplaceable one; AWS
Backup selects the volume by ARN, not by tag). Prints
the new volume ID. The original volume is untouched.

You'll be asked to confirm before anything destructive happens. The snapshot
wait can take several minutes.

## Step 3 — adopt (automated; state surgery, gated)

```sh
./scripts/azmove.sh adopt vol-0newvolume <az>
```

Backs up Terraform state to `azmove-state-<timestamp>.json`, sanity-checks the
new volume (right AZ, right tag), removes the old volume from state (the AWS
resource is left intact), imports the new one under the same address, and sets
`az` in `terraform.tfvars`. Confirmation required before the state edit.

## Step 4 — review and apply (MANUAL — do not skip)

```sh
scripts/tf.sh prod plan
```

Confirm in the plan:

- the data volume is a **no-op** — if it shows as destroyed, **stop** and
  restore state from the backup;
- the public subnet is replaced (it's empty now, so that's safe);
- the launch template gets a new version and the `AttachVolume` IAM policy
  updates to the new volume ARN.

Then:

```sh
scripts/tf.sh prod apply
```

Apply must happen before scale-up. The `AttachVolume` IAM policy is scoped to
the volume's ARN; until apply updates it to the new ARN, a launching instance
is denied the attach.

## Step 5 — finish (automated)

```sh
./scripts/azmove.sh finish https://<your-primary-domain>/
```

Scales the ASG back to 1, waits for an InService instance, and (if you pass a
URL) polls it until healthy. CodeDeploy auto-deploys the last revision on boot,
so allow a few minutes. The new instance attaches the restored volume, sees the
existing filesystem, mounts the data, and reassociates the EIP.

## Step 6 — clean up (MANUAL)

After a few days of confidence:

```sh
aws ec2 delete-volume --region <primary_region> --volume-id vol-0oldvolume
```

The script never deletes the old volume — it's your rollback until you're sure.

## Rollback

Nothing destroys data before Step 4. Until you apply:

- The original volume and the snapshot both still exist.
- To abandon the move: `terraform state push -force azmove-state-<timestamp>.json`
  to restore the pre-adopt state (`-force`: the adopt's `state rm` raised the
  serial), revert `az` in `terraform.tfvars`, scale the ASG back to 1,
  and delete the restored volume you created in Step 2.

After a failed apply, the original volume is still intact; re-point state at it
the same way and re-apply.

## Recovery time

This is minutes, not seconds: the snapshot in Step 2 and the on-boot CodeDeploy
run in Step 5 dominate. Budget for downtime accordingly — it's a deliberate,
gated procedure, not a hot failover.
