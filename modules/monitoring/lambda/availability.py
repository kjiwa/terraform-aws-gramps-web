"""Availability monitor for gramps-web. One function, four event sources:

1. EventBridge schedule (every minute): probe the site end-to-end through
   CloudFront and publish SiteUp / LatencyMs metrics, unconditionally --
   see probe(). The site_down alarm is the single source of truth for
   "down"; it watches SiteUp (monitoring/alerts.tf).
2. EC2 Spot Instance Interruption Warning: enrich with instance details and
   stash in the SSM state parameter so the next outage can be attributed to
   the reclaim. No email here; the DOWN email carries the cause.
3. CloudWatch Alarm State Change (ALARM/OK): send DOWN / RECOVERED emails and
   append one JSON line per completed outage to the episodes log group for
   Logs Insights aggregation.
4. CodeDeploy deployment and Auto Scaling instance-refresh completion events:
   append one JSON line per deliberate change to the `changes` stream of the
   same log group, whether or not the site went down (see handle_deployment()
   and handle_instance_refresh()). The status Lambda derives whether a change
   caused an outage by overlapping it with the episodes, and collapses a
   redelivered event to one record by id.

Outage edges (start and recovery) come from the same per-minute metric the
alarm is actually watching (SiteUp), not the alarm state-change event: the
first failing datapoint, and the first passing datapoint after the last
failing one. This is probe-resolution (~1 min) and free of the alarm's
evaluation lag, which otherwise pushes both the DOWN "since" and the RECOVERED
time ~2 min late. The alarm event still triggers the emails and gates
detection, so outages shorter than its threshold (~2 min) remain invisible by
design. If the metric query fails or has no datapoint for an edge, that edge
falls back to the alarm timestamp (logged, email still sent).

Cause attribution (classify_cause()) tries an ordered list of checks and
takes the first match, falling through to "unknown". The DOWN email carries
the cause as known at that moment; the episode is classified again at
RECOVERED, once every marker and AWS record up to the recovery exists, so the
episode's cause never depends on what was visible when the alarm fired:

  1. spot-reclaim     -- an EC2 Spot Interruption Warning (source #2 above)
                         landed shortly before the outage started.
  2. rightsize        -- build/ami/rightsize-watchdog.sh wrote its marker to a
                         dedicated SSM parameter while replacing the instance.
  3. health-watchdog  -- same idea: build/ami/health-watchdog.sh's
                         set_unhealthy() writes its marker while marking the
                         instance Unhealthy over a dead app.
  4. backup           -- scripts/backup.sh snapshot wrote its marker just
                         before stopping the app.
  5. deploy           -- pulled, not pushed: a CodeDeploy deployment created by
                         a person or a rollback (DELIBERATE_DEPLOYMENT_CREATORS)
                         around the outage. Deployments the ASG creates for
                         every launched instance are consequences, not causes.
  6. instance-refresh -- pulled: the ASG's instance-refresh history.
  7. capacity-change  -- pulled: an ASG scaling activity caused by a change of
                         desired capacity.
  8. health-replace   -- pulled: an ASG replacement of an unhealthy instance
                         that no watchdog marker explains.
  9. unknown          -- nothing matched.

Markers (1-4) are matched by MARKER_LEAD_BEFORE_OUTAGE_S or
MARKER_LEAD_AFTER_APP_STOPPED_S, whichever fits when the marker is written.
Pulled records (5-8) carry precise timestamps and match when they fall between
PULLED_ATTRIBUTION_WINDOW_S before the outage start and its end.

Every episode carries a `planned` boolean (see PLANNED_CAUSES), which the
status page reads to compute an uptime series that excludes planned
maintenance, plus capacity_wait_s, boot_to_serve_s, lifecycle, and spot_price
describing how the replacement instance came up.
"""

import datetime
import json
import os
import time
import urllib.error
import urllib.request

import boto3
from botocore.config import Config

SITE_URL = os.environ["SITE_URL"]
ASG_NAME = os.environ["ASG_NAME"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
STATE_PARAM = os.environ["STATE_PARAM"]
EPISODES_LOG_GROUP = os.environ["EPISODES_LOG_GROUP"]
EPISODES_LOG_STREAM = os.environ["EPISODES_LOG_STREAM"]
CHANGES_LOG_STREAM = os.environ["CHANGES_LOG_STREAM"]
METRIC_NAMESPACE = os.environ["METRIC_NAMESPACE"]
CODEDEPLOY_APP_NAME = os.environ["CODEDEPLOY_APP_NAME"]
CODEDEPLOY_DEPLOYMENT_GROUP = os.environ["CODEDEPLOY_DEPLOYMENT_GROUP"]
LAST_RIGHTSIZE_PARAM = os.environ["LAST_RIGHTSIZE_PARAM"]
LAST_HEALTH_WATCHDOG_PARAM = os.environ["LAST_HEALTH_WATCHDOG_PARAM"]
LAST_BACKUP_SNAPSHOT_PARAM = os.environ["LAST_BACKUP_SNAPSHOT_PARAM"]
DELIBERATE_DEPLOYMENT_CREATORS = set(
    os.environ["DELIBERATE_DEPLOYMENT_CREATORS"].split(",")
)

# `started` is the first failing probe floored to the minute, and each marker
# is written at a different point relative to the app stopping, so a marker is
# matched by lead = started - marker time. A marker written before the app
# stops (Spot warning, backup snapshot) leads the outage by up to the alarm and
# probe lag, and can trail the floored start by the floor. A marker written
# after the app stopped (rightsize after its drain, health watchdog after ten
# failed one-minute ticks) trails the outage by up to ~12 minutes and cannot
# lead it by more than the floor.
MARKER_FLOOR_S = 90
MARKER_LAG_S = 15 * 60
MARKER_LEAD_BEFORE_OUTAGE_S = (-MARKER_FLOOR_S, MARKER_LAG_S)
MARKER_LEAD_AFTER_APP_STOPPED_S = (-MARKER_LAG_S, MARKER_FLOOR_S)

# Pulled AWS records (deployments, instance refreshes, scaling activities)
# match from this long before the outage start to the outage end: the cause
# precedes the first failing probe by the canary/alarm lag, while a
# replacement can land anywhere inside the outage.
PULLED_ATTRIBUTION_WINDOW_S = 10 * 60

# Causes that represent a deliberate, self-inflicted interruption rather than
# an involuntary loss of capacity. Stored on each episode as `planned`, which
# the status page reads as-is.
PLANNED_CAUSES = {
    "rightsize",
    "deploy",
    "instance-refresh",
    "capacity-change",
    "backup",
}

# How far to widen the metric query around the alarm timestamps when hunting
# for the real edges. The alarm fires within ~3 min of the first failing probe
# and clears within ~3 min of the first passing one, so 4 min brackets both
# edges without reaching back into an unrelated earlier blip.
EDGE_PAD_S = 4 * 60

PROBE_TIMEOUT_S = 8

# Fragments of an ASG scaling activity's Cause (lower case). A desired-capacity
# change reads "...changing the desired capacity from X to Y"; a replacement
# of a failed instance reads "...an unhealthy instance needing to be replaced"
# on the launch, and names a health check on the termination.
DESIRED_CAPACITY_CAUSE = "changing the desired capacity"
UNHEALTHY_CAUSE = "health"
SCALING_ACTIVITY_PAGE = 100

# Terminal states only; in-flight states carry no outcome and write nothing.
DEPLOYMENT_DETAIL_TYPE = "CodeDeploy Deployment State-change Notification"
DEPLOYMENT_OUTCOMES = {"SUCCESS": "succeeded", "FAILURE": "failed", "STOP": "stopped"}
REFRESH_DETAIL_PREFIX = "EC2 Auto Scaling Instance Refresh "
REFRESH_OUTCOMES = {
    "Succeeded": "succeeded",
    "Failed": "failed",
    "Cancelled": "cancelled",
    "Rollback Succeeded": "rollback-succeeded",
    "Rollback Failed": "rollback-failed",
}

# Bounds every AWS call: the botocore defaults (60s connect/read, 3 attempts)
# would let one hung call consume the Lambda's whole timeout.
BOTO_CONFIG = Config(
    connect_timeout=3, read_timeout=8, retries={"max_attempts": 2, "mode": "standard"}
)

cloudwatch = boto3.client("cloudwatch", config=BOTO_CONFIG)
ec2 = boto3.client("ec2", config=BOTO_CONFIG)
autoscaling = boto3.client("autoscaling", config=BOTO_CONFIG)
codedeploy = boto3.client("codedeploy", config=BOTO_CONFIG)
ssm = boto3.client("ssm", config=BOTO_CONFIG)
sns = boto3.client("sns", config=BOTO_CONFIG)
logs = boto3.client("logs", config=BOTO_CONFIG)


def handler(event, context):
    detail_type = event.get("detail-type", "")
    if detail_type == "EC2 Spot Instance Interruption Warning":
        handle_interruption(event)
    elif detail_type == "CloudWatch Alarm State Change":
        handle_alarm(event)
    elif detail_type == DEPLOYMENT_DETAIL_TYPE:
        handle_deployment(event)
    elif detail_type.startswith(REFRESH_DETAIL_PREFIX):
        handle_instance_refresh(event)
    else:  # EventBridge "Scheduled Event"
        probe()


# --- canary -------------------------------------------------------------------


def probe():
    """GET the site through CloudFront, exactly like a user. 2xx/3xx = up.

    CloudFront preserves the origin's real status on its custom error pages
    (response_code = error_code), which is what lets this end-to-end probe see
    an origin outage instead of a styled 200.
    """
    req = urllib.request.Request(
        SITE_URL, headers={"User-Agent": "gramps-availability-canary"}
    )
    start = time.monotonic()
    up, code, err = 0, None, None
    try:
        with urllib.request.urlopen(req, timeout=PROBE_TIMEOUT_S) as resp:
            code = resp.status
            up = 1  # urlopen only returns for 2xx/3xx
    except urllib.error.HTTPError as e:
        code = e.code
    except Exception as e:  # DNS, TLS, timeout, connection refused
        err = f"{type(e).__name__}: {e}"
    latency_ms = (time.monotonic() - start) * 1000

    metrics = [{"MetricName": "SiteUp", "Value": up, "Unit": "None"}]
    if code is not None:
        metrics.append(
            {"MetricName": "LatencyMs", "Value": latency_ms, "Unit": "Milliseconds"}
        )
    cloudwatch.put_metric_data(Namespace=METRIC_NAMESPACE, MetricData=metrics)

    print(
        json.dumps(
            {
                "probe": SITE_URL,
                "up": up,
                "code": code,
                "ms": round(latency_ms),
                "error": err,
            }
        )
    )


# --- spot interruption ----------------------------------------------------------


def handle_interruption(event):
    instance_id = event["detail"]["instance-id"]
    info = describe_instance(instance_id)
    state = load_state()
    state["last_interruption"] = {"time": event["time"], **info}
    save_state(state)
    print(json.dumps({"interruption": state["last_interruption"]}))


# --- change log -----------------------------------------------------------------


def handle_deployment(event):
    detail = event["detail"]
    outcome = DEPLOYMENT_OUTCOMES.get(detail["state"])
    if not outcome:
        return
    deployment_id = detail["deploymentId"]
    info = tolerant(
        "get_deployment",
        lambda: codedeploy.get_deployment(deploymentId=deployment_id)["deploymentInfo"],
        {},
    )
    write_change(
        event,
        kind="deploy",
        id=deployment_id,
        outcome=outcome,
        creator=info.get("creator"),
        started=info.get("createTime"),
        ended=info.get("completeTime"),
        description=info.get("description"),
    )


def handle_instance_refresh(event):
    outcome = REFRESH_OUTCOMES.get(
        event["detail-type"].removeprefix(REFRESH_DETAIL_PREFIX)
    )
    if not outcome:
        return
    refresh_id = event["detail"]["InstanceRefreshId"]
    refresh = describe_instance_refresh(refresh_id)
    write_change(
        event,
        kind="instance-refresh",
        id=refresh_id,
        outcome=outcome,
        creator=None,
        started=refresh.get("StartTime"),
        ended=refresh.get("EndTime"),
        description=refresh.get("StatusReason"),
    )


def describe_instance_refresh(refresh_id):
    refreshes = tolerant(
        "describe_instance_refreshes",
        lambda: autoscaling.describe_instance_refreshes(
            AutoScalingGroupName=ASG_NAME, InstanceRefreshIds=[refresh_id]
        )["InstanceRefreshes"],
        None,
    )
    if refreshes == []:
        print(json.dumps({"instance_refresh_not_found": refresh_id}))
    return refreshes[0] if refreshes else {}


def write_change(event, **fields):
    """Append one change line. The log timestamp is the event's own time, so a
    redelivered event writes the identical line; readers keep one record per id.
    A failed write raises, so EventBridge retries the delivery.
    """
    event_time = parse_ts(event["time"])
    record = change_record(event_time, **fields)
    logs.put_log_events(
        logGroupName=EPISODES_LOG_GROUP,
        logStreamName=CHANGES_LOG_STREAM,
        logEvents=[
            {
                "timestamp": int(event_time.timestamp() * 1000),
                "message": json.dumps(record),
            }
        ],
    )
    print(json.dumps({"change": record}))


def change_record(
    event_time, *, kind, id, outcome, creator, started, ended, description
):
    """The change-log line shape; `ended` falls back to the event's time."""
    ended = ended or event_time
    return {
        "at": iso(ended),
        "kind": kind,
        "id": id,
        "creator": creator,
        "outcome": outcome,
        "duration_s": int((ended - started).total_seconds()) if started else None,
        "description": description,
    }


# --- alarm transitions ----------------------------------------------------------


def handle_alarm(event):
    detail = event["detail"]
    value = detail["state"]["value"]
    if value == "ALARM":
        handle_down(detail)
    elif value == "OK":
        handle_recovered(detail)


def handle_down(detail):
    alarm_started = parse_ts(detail["state"]["timestamp"])
    now = datetime.datetime.now(datetime.UTC)
    started = first_down(edge_metric_series(alarm_started, now), alarm_started)
    state = load_state()
    interruption = state.get("last_interruption")

    cause = classify_cause(started, now, interruption)

    state["outage"] = {"started": iso(started), "cause": cause}
    save_state(state)

    lines = [f"{SITE_URL} is DOWN (since {iso(started)})."]
    if cause == "spot-reclaim":
        i = interruption
        lines.append(
            f"Cause: Spot reclaim of {i['id']} ({i['type']}, {i['az']}, {i['arch']}) at {i['time']}."
        )
        lines.append(
            "The ASG is requesting replacement Spot capacity; recovery time depends on availability."
        )
        subject = f"[gramps-web] DOWN - spot reclaim of {i['type']}"
    elif cause == "unknown":
        lines.append(
            "Cause: unknown so far; no marker or ASG/CodeDeploy record explains it yet. "
            "The RECOVERED email carries the cause once the replacement is serving."
        )
        subject = "[gramps-web] DOWN - cause unknown"
    else:
        lines.append(f"Cause: {cause}.")
        subject = f"[gramps-web] DOWN - {cause}"
    lines.append("A RECOVERED email with the outage duration will follow.")

    notify(subject, "\n".join(lines))


def handle_recovered(detail):
    if detail.get("previousState", {}).get("value") != "ALARM":
        return  # e.g. INSUFFICIENT_DATA -> OK on first deploy; not an outage

    state = load_state()
    if "outage" not in state:
        notify_wake()
        return

    alarm_ended = parse_ts(detail["state"]["timestamp"])
    alarm_started = parse_ts(detail["previousState"]["timestamp"])
    series = edge_metric_series(alarm_started, alarm_ended)
    started = first_down(series, alarm_started)
    ended = recovery(series, alarm_ended)
    duration_s = int((ended - started).total_seconds())

    state.pop("outage")
    cause = classify_cause(started, ended, state.get("last_interruption"))
    planned = cause in PLANNED_CAUSES
    # Consume the interruption once attributed, so a later unrelated outage
    # can't be mis-tagged spot-reclaim off this same stale warning.
    old = state.pop("last_interruption", None) if cause == "spot-reclaim" else None

    new = current_asg_instance()
    facts = launch_facts(new, started, ended)
    activity = last_scaling_activity()

    lines = [
        f"{SITE_URL} RECOVERED after {fmt_duration(duration_s)} (down {iso(started)} - {iso(ended)})."
    ]
    lines.append(f"Cause: {cause}.")
    if old:
        lines.append(
            f"Reclaimed: {old['id']} ({old['type']}, {old['az']}, {old['arch']})."
        )
    if new:
        lines.append(
            f"Now serving: {new['id']} ({new['type']}, {new['az']}, {new['arch']}), launched {new['launched']}."
        )
        wait_s = facts["capacity_wait_s"]
        if cause == "spot-reclaim" and wait_s > 0:
            # Splits "waiting for Spot capacity" from "boot + deploy" time.
            lines.append(
                f"Capacity wait ~{fmt_duration(wait_s)}; boot + deploy ~{fmt_duration(duration_s - wait_s)}."
            )
    if activity:
        lines.append(f"Last ASG activity: {activity}")

    notify(
        f"[gramps-web] RECOVERED after {fmt_duration(duration_s)} - {cause}",
        "\n".join(lines),
    )

    episode = {
        "started": iso(started),
        "ended": iso(ended),
        "duration_s": duration_s,
        "cause": cause,
        "planned": planned,
        "old_instance": old,
        "new_instance": new,
        **facts,
    }
    logs.put_log_events(
        logGroupName=EPISODES_LOG_GROUP,
        logStreamName=EPISODES_LOG_STREAM,
        logEvents=[
            {"timestamp": int(ended.timestamp() * 1000), "message": json.dumps(episode)}
        ],
    )
    save_state(state)
    print(json.dumps({"episode": episode}))


def notify_wake():
    """The alarm cleared with no open outage: the DOWN handler never ran
    because the alarm rule is disabled while the environment sleeps. The
    alarm's own edges span the sleep, not an outage, so no episode is
    recorded.
    """
    notify(
        "[gramps-web] RECOVERED - woke from sleep",
        f"{SITE_URL} is serving again after the environment slept.",
    )


# --- cause attribution -----------------------------------------------------------


def classify_cause(started, ended, interruption):
    """Ordered attribution checks for an outage spanning started..ended; first
    match wins, falling through to "unknown". See the module docstring for
    the ordering and the matching windows.
    """
    if attributed_by_marker(interruption, started, *MARKER_LEAD_BEFORE_OUTAGE_S):
        return "spot-reclaim"
    if attributed_by_marker(
        load_marker(LAST_RIGHTSIZE_PARAM), started, *MARKER_LEAD_AFTER_APP_STOPPED_S
    ):
        return "rightsize"
    if attributed_by_marker(
        load_marker(LAST_HEALTH_WATCHDOG_PARAM),
        started,
        *MARKER_LEAD_AFTER_APP_STOPPED_S,
    ):
        return "health-watchdog"
    if attributed_by_marker(
        load_marker(LAST_BACKUP_SNAPSHOT_PARAM), started, *MARKER_LEAD_BEFORE_OUTAGE_S
    ):
        return "backup"
    since = started - datetime.timedelta(seconds=PULLED_ATTRIBUTION_WINDOW_S)
    if recent_deployment(since, ended):
        return "deploy"
    if recent_instance_refresh(since, ended):
        return "instance-refresh"
    if recent_scaling_cause(since, ended, DESIRED_CAPACITY_CAUSE):
        return "capacity-change"
    if recent_scaling_cause(since, ended, UNHEALTHY_CAUSE):
        return "health-replace"
    return "unknown"


def attributed_by_marker(marker, started, min_lead_s, max_lead_s):
    """True if `marker` (a {"time": ..., ...} dict, or None/{} if nothing has
    ever been written) was written between min_lead_s and max_lead_s before
    `started`; a negative lead is a marker written after `started`. The
    marker's other keys (id/type/az/arch for a Spot interruption,
    instance_id for the watchdogs) are the caller's business.
    """
    if not marker or "time" not in marker:
        return False
    lead_s = (started - parse_ts(marker["time"])).total_seconds()
    return min_lead_s <= lead_s <= max_lead_s


def load_marker(param_name):
    """SSM parameter written by a script just before or while it acts (see
    the module docstring): {"time": ..., "instance_id": ...}. Returns {} --
    same as attributed_by_marker's "nothing written yet" case -- both when the
    parameter holds its pre-write "{}" default and when it predates this
    stack's Terraform apply entirely; a missing marker parameter must not
    crash cause attribution.
    """
    try:
        return json.loads(ssm.get_parameter(Name=param_name)["Parameter"]["Value"])
    except ssm.exceptions.ParameterNotFound:
        return {}


def tolerant(name, lookup, default):
    """Run one AWS lookup. Any API failure (throttle, transient IAM issue)
    degrades to `default` rather than raising: a broken enrichment must never
    take down the email or change-log pipeline it feeds into.
    """
    try:
        return lookup()
    except Exception as e:
        print(json.dumps({f"{name}_failed": f"{type(e).__name__}: {e}"}))
        return default


def history_matches(name, check):
    """Run one AWS-history check; a failed lookup reads as "not matched"."""
    return tolerant(name, check, False)


def recent_deployment(since, until):
    """True if a person (or a rollback) created a CodeDeploy deployment for
    this app/group between `since` and `until`. Mirrors
    modules/status/lambda/status.py's deployment() query.
    """

    def check():
        ids = codedeploy.list_deployments(
            applicationName=CODEDEPLOY_APP_NAME,
            deploymentGroupName=CODEDEPLOY_DEPLOYMENT_GROUP,
            createTimeRange={"start": since, "end": until},
        ).get("deployments", [])
        if not ids:
            return False
        details = codedeploy.batch_get_deployments(deploymentIds=ids[:25])[
            "deploymentsInfo"
        ]
        return any(d.get("creator") in DELIBERATE_DEPLOYMENT_CREATORS for d in details)

    return history_matches("recent_deployment", check)


def recent_instance_refresh(since, until):
    """True if the ASG has an instance refresh whose StartTime falls between
    `since` and `until`.
    """

    def check():
        r = autoscaling.describe_instance_refreshes(AutoScalingGroupName=ASG_NAME)
        return any(
            since <= refresh["StartTime"] <= until
            for refresh in r.get("InstanceRefreshes", [])
            if refresh.get("StartTime")
        )

    return history_matches("recent_instance_refresh", check)


def recent_scaling_cause(since, until, cause_fragment):
    """True if an ASG scaling activity started between `since` and `until`
    with `cause_fragment` in its Cause (case-insensitive).
    """

    def check():
        r = autoscaling.describe_scaling_activities(
            AutoScalingGroupName=ASG_NAME, MaxRecords=SCALING_ACTIVITY_PAGE
        )
        return any(
            a.get("StartTime")
            and since <= a["StartTime"] <= until
            and cause_fragment in (a.get("Cause") or "").lower()
            for a in r.get("Activities", [])
        )

    return history_matches("recent_scaling_cause", check)


# --- edge refinement ------------------------------------------------------------
# The alarm event's timestamps lag the real edges by the evaluation window. The
# per-minute SiteUp metric the alarm is actually watching carries the true
# edges at probe resolution, so the emails and the episode log read from it instead, falling
# back to the alarm timestamp whenever a datapoint is missing.


def edge_metric_series(start, end):
    """Sorted (timestamp, value) datapoints, over a padded window, for
    the SiteUp metric site_down alarms on, a single aggregated 0/1 series at
    1-minute granularity.

    Returns [] on any query failure; callers then fall back to alarm timestamps.
    """
    try:
        r = cloudwatch.get_metric_data(
            MetricDataQueries=[
                {
                    "Id": "edge",
                    "MetricStat": {
                        "Metric": {
                            "Namespace": METRIC_NAMESPACE,
                            "MetricName": "SiteUp",
                        },
                        "Period": 60,
                        "Stat": "Minimum",
                    },
                    "ReturnData": True,
                }
            ],
            StartTime=start - datetime.timedelta(seconds=EDGE_PAD_S),
            EndTime=end + datetime.timedelta(seconds=EDGE_PAD_S),
            ScanBy="TimestampAscending",
        )
    except (
        Exception
    ) as e:  # IAM, throttle: degrade to alarm edges, do not drop the email
        print(json.dumps({"edge_metric_series_failed": f"{type(e).__name__}: {e}"}))
        return []
    result = r["MetricDataResults"][0]
    return sorted(zip(result["Timestamps"], result["Values"]))


def first_down(series, fallback):
    """Timestamp of the first failing datapoint; outage start."""
    downs = [ts for ts, value in series if value < 1]
    return min(downs) if downs else fallback


def recovery(series, fallback):
    """Timestamp of the first passing datapoint after the last failing one.

    Anchoring to the last failure (not the first pass) keeps a mid-outage flap
    from cutting the outage short.
    """
    downs = [ts for ts, value in series if value < 1]
    if not downs:
        return fallback
    ups = [ts for ts, value in series if value >= 1 and ts > max(downs)]
    return min(ups) if ups else fallback


# --- AWS lookups ----------------------------------------------------------------


def describe_instance(instance_id):
    r = ec2.describe_instances(InstanceIds=[instance_id])
    i = r["Reservations"][0]["Instances"][0]
    return {
        "id": instance_id,
        "type": i["InstanceType"],
        "az": i["Placement"]["AvailabilityZone"],
        "arch": i["Architecture"],
        "launched": iso(i["LaunchTime"]),
        "lifecycle": "spot" if i.get("InstanceLifecycle") == "spot" else "on-demand",
    }


def launch_facts(new, started, ended):
    """How the replacement came up: the wait for capacity (outage start to
    launch), the boot-to-serve time (launch to recovery), and what it ran on.
    All None when no instance is in service.
    """
    if not new:
        return {
            "capacity_wait_s": None,
            "boot_to_serve_s": None,
            "lifecycle": None,
            "spot_price": None,
        }
    launched = parse_ts(new["launched"])
    return {
        "capacity_wait_s": max(0, int((launched - started).total_seconds())),
        "boot_to_serve_s": max(0, int((ended - launched).total_seconds())),
        "lifecycle": new["lifecycle"],
        "spot_price": spot_price_at(new) if new["lifecycle"] == "spot" else None,
    }


def spot_price_at(instance):
    """USD/h Spot price in effect for the instance's type and AZ at launch, or
    None if the lookup fails. Equal StartTime and EndTime return the price in
    effect at that moment.
    """
    launched = parse_ts(instance["launched"])
    try:
        r = ec2.describe_spot_price_history(
            InstanceTypes=[instance["type"]],
            AvailabilityZone=instance["az"],
            ProductDescriptions=["Linux/UNIX"],
            StartTime=launched,
            EndTime=launched,
            MaxResults=1,
        )
        return float(r["SpotPriceHistory"][0]["SpotPrice"])
    except Exception as e:
        print(json.dumps({"spot_price_failed": f"{type(e).__name__}: {e}"}))
        return None


def current_asg_instance():
    r = autoscaling.describe_auto_scaling_groups(AutoScalingGroupNames=[ASG_NAME])
    instances = r["AutoScalingGroups"][0]["Instances"]
    if not instances:
        return None
    try:
        return describe_instance(instances[0]["InstanceId"])
    except (
        Exception
    ) as e:  # raced a terminating instance; email still useful without it
        print(json.dumps({"describe_instance_failed": str(e)}))
        return None


def last_scaling_activity():
    r = autoscaling.describe_scaling_activities(
        AutoScalingGroupName=ASG_NAME, MaxRecords=1
    )
    if not r["Activities"]:
        return None
    a = r["Activities"][0]
    return f"{a['Description']} ({iso(a['StartTime'])})"


# --- state + helpers -------------------------------------------------------------


def load_state():
    try:
        return json.loads(ssm.get_parameter(Name=STATE_PARAM)["Parameter"]["Value"])
    except ssm.exceptions.ParameterNotFound:  # first-apply race only
        return {}


def save_state(state):
    ssm.put_parameter(
        Name=STATE_PARAM, Value=json.dumps(state), Type="String", Overwrite=True
    )


def notify(subject, body):
    sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject[:100], Message=body)


def parse_ts(ts):
    """Both event formats: '2026-06-11T20:09:11Z' and '2026-06-11T20:09:11.123+0000'."""
    ts = ts.replace("Z", "+00:00")
    if "+" in ts and ":" not in ts.split("+")[1]:
        ts = ts[:-2] + ":" + ts[-2:]
    return datetime.datetime.fromisoformat(ts)


def iso(dt):
    return dt.astimezone(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def fmt_duration(seconds):
    seconds = max(0, int(seconds))
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h {m}m"
    if m:
        return f"{m}m {s}s"
    return f"{s}s"
