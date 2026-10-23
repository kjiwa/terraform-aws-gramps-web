# Status page

Enabled with `status.enabled`. The page lives at `/_status` on the site, a static shell in S3 that fetches its data from a Lambda behind the same CloudFront distribution.

![Public status page, light, 1440 px](images/status-light.png)

![Public status page, dark, 393 px](images/status-dark-mobile.png)

## Public and authenticated routes

| Route | Access | Contents |
|---|---|---|
| `/_status` | The shell is static and open; the page renders what the routes below allow. | |
| `/_status/public` | Unauthenticated; exists only when `status.public_reliability` is true. Cached by CloudFront for up to five minutes. | Uptime ranges, incidents, deliberate changes, Spot warning times. Redacted by allowlist. |
| `/_status/data` | Gramps Web sign-in with a role at or above `status.min_role`. | Everything public, plus host, image, storage, deployment, backups, and the optional assistant, cost, and host-metric panels. |
| `/_status/series` | Same as `/_status/data`. | One panel for a panned time range. |

Authentication forwards the caller's token to the site's own `/api/users/-/` and compares the returned role, so the authenticated routes stop working while the app is down. The public route has no dependency on the app, which is why it still renders during an outage. A panel whose AWS call fails degrades to an error note instead of failing the page, and a degraded public response is cached for ten seconds, not five minutes.

The public route republishes only these fields:

| Section | Fields |
|---|---|
| `incidents` | `started`, `duration_s`, `cause`, `planned` |
| `changes` | `at`, `kind`, `creator`, `outcome`, deliberate changes only |
| `interruptions` | `time` |
| `reliability` | The same payload as the authenticated page |

Instance IDs, instance types, zones, deployment IDs, and descriptions stay private. The cause and the planned flag are disclosed on purpose: they show that production runs on preemptible capacity and is redeployed automatically.

## Data sources

| Source | Written by | Read for |
|---|---|---|
| `SiteUp` and latency metrics | The availability Lambda probes the site through CloudFront every minute. | Uptime tiles, the strip (a cell's readout names its incidents), latency, and the exact edges of every outage. |
| Episodes log | The availability Lambda appends one JSON line per completed outage. | Incidents, causes, recovery timing. |
| Change log | The availability Lambda appends one line per finished CodeDeploy deployment and ASG instance refresh, from EventBridge events. | Changes. |
| Spot interruption log | An EventBridge rule writes every EC2 Spot Interruption Warning to a log group (365-day retention). | Spot reclaim counts. |
| Cause markers | SSM parameters holding `{time, instance_id}`, written by the host watchdogs and `scripts/backup.sh`. | Cause attribution. |
| CodeDeploy and Auto Scaling | Read directly by the status Lambda for the live panels, and by the availability Lambda for cause attribution. | Deployment, host, and the pulled causes below. |

An outage is recorded only when the `site_down` alarm fires, so outages shorter than its threshold (about two minutes) never become an incident. Outage start and end come from the per-minute `SiteUp` series, not from the alarm timestamps. The start is the first failing minute; the end is the first passing minute after the last failing one.

## Incident causes

Each recorded outage carries one cause. Checks run in the order below and the first match wins. The DOWN email states the cause known at that moment; the episode is classified again on recovery, once every marker and AWS record exists, so the stored cause does not depend on timing at alarm time.

A marker matches by when it was written relative to the outage start. A marker written before the app stops matches from 15 minutes before the start to 90 seconds after it. A marker written after the app has stopped matches from 90 seconds before to 15 minutes after. Pulled AWS records match from 10 minutes before the start through the end of the outage.

| Cause | Planned | How it is determined |
|---|---|---|
| `spot-reclaim` | no | An EC2 Spot Interruption Warning was recorded for an instance in the account, written before the app stops. Consumed once attributed, so one warning explains one outage. |
| `rightsize` | yes | The rightsize watchdog (`rightsize.schedule`) wrote its marker while replacing the instance with one from a cheaper pool. Marker written after the app stopped. |
| `health-watchdog` | no | The health watchdog marked the instance Unhealthy after ten consecutive failed local checks, one per minute, and wrote its marker. Marker written after the app stopped. |
| `backup` | yes | `scripts/backup.sh snapshot` wrote its marker just before stopping the app for an app-consistent snapshot. |
| `deploy` | yes | A CodeDeploy deployment for the app and group was created in the window by a person (`user`) or a rollback (`codeDeployRollback`). Deployments created by Auto Scaling for each launched instance are consequences, not causes, and do not match. |
| `instance-refresh` | yes | An ASG instance refresh started in the window. |
| `capacity-change` | yes | An ASG scaling activity in the window whose cause reads "changing the desired capacity". |
| `health-replace` | no | An ASG scaling activity in the window whose cause names a health check, with no watchdog marker to explain it. A Spot reclaim whose warning was missed lands here, because every replacement of an instance marked Unhealthy carries the same wording. |
| `unknown` | no | Nothing matched. |

Waking from sleep is not a cause. The alarm is disabled while the site sleeps, so waking records no incident; it sends a "woke from sleep" email.

The `planned` flag is true for `rightsize`, `deploy`, `instance-refresh`, `capacity-change`, and `backup`. The "Unplanned only" toggle recomputes uptime without planned windows: planned episodes, plus every deliberate CodeDeploy deployment window, including ones too short to trip the alarm.

A change record is marked as having caused an outage when an episode of the same kind overlaps it within 90 seconds. A deployment that overlaps an episode of another cause, or an Auto Scaling launch deployment, is not blamed.

## Incidents card

Ranges are 24 hours, 7 days, 30 days, 90 days, and one year, the same as the reliability card. The chart stacks incidents per cell by cause class. Arrows pan the window within the last year in the browser, including on the public route. The table lists the incidents in the window.

### Spot

A subsection of the card, shown when the deployment has Spot activity. It follows the card's range.

| Figure | Definition |
|---|---|
| Reclaims | Spot interruption warnings in range. |
| Caused an outage | Incidents with cause `spot-reclaim` in range. |
| Share of downtime | Downtime of the `spot-reclaim` incidents over the downtime of every incident in range. |

The authenticated page adds two views that need instance details. The recovery split shows the median capacity wait (outage start to replacement launch) against the median boot-to-serve time (launch to recovery); it appears once at least three incidents in the selected range carry both timings; until then a note states how many do. The Pools table groups reclaims by the lost instance's type and zone, with the median instance lifetime and the most recent reclaim, folding the tail into an "Other" row.

## Changes card

Under Delivery. The Deliberate|All toggle defaults to Deliberate: user and rollback deployments and instance refreshes. All adds deployments created by Auto Scaling. The toggle is hidden when no other changes exist, which includes the public route. Each row shows time, change, outcome, duration, and whether it caused an outage.

## Layout and loading

Sections are Service (Reliability, Incidents), Delivery (Deployment, Changes), Data (Backups, Storage), Runtime (Host, Assistant), and Spend (Cost). A panel that times out shows "Didn't load in time." with a Retry button that refetches it.

The Lambdas read the episodes and Spot logs with CloudWatch Logs Insights, once per log group per request. The status role needs `logs:StartQuery` and `logs:GetQueryResults` on those log groups.
