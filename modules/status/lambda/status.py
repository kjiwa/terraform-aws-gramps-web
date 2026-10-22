"""Operational status page for gramps-web, served at /_status. One function,
three responsibilities -- the shell itself (GET /_status, /_status/) is a
static object in S3 (build/web/src/status/, published by deploy.sh web), not
this Lambda; it fetches its data from the routes below:

1. Auth (every gated route below): Gramps Web is the sole identity authority.
   The caller's token is forwarded to GET {SITE_URL}/api/users/-/ on the site
   itself and the returned `role` integer is compared against MIN_ROLE's
   threshold (see ROLES below). No local user directory, no separate login --
   and the honest cost of that is that this page does not work while the app
   itself is down. That is by design, not an oversight, and is exactly the
   gap responsibility 3 exists to close for the reliability panel specifically.
2. Data and history (gated GET /_status/data, GET /_status/series): one JSON
   response assembled from CloudWatch, EC2, Auto Scaling, CodeDeploy, ECR,
   Logs, AWS Backup, Cost Explorer, and Bedrock metrics. Each panel is its
   own function, called from collect_status() through a per-section
   try/except: one panel's AWS API failure degrades that panel to
   {"error": ...} rather than 500ing the whole page. Panels run concurrently
   on a thread pool -- boto3 clients are thread-safe -- except image, which
   depends on host's AMI ID and so shares host's worker instead of racing
   it. /_status/series answers "this one panel, this one range, ending at
   this instant" for the three panels with their own range selector
   (reliability, host_metrics, assistant) by calling the same panel function
   with an explicit `now`/`keys` instead of the live default -- see
   series_response() and reliability()'s docstring for the shared contract.
   incidents has no range selector to pan (it already ships its full
   365-day window in one response), so it is deliberately not one of the
   three. /_status/series sits behind the same auth as /_status/data, with
   no public variant: panning fans out into CloudWatch GetMetricData per
   request, and keeping it authenticated bounds that to a caller who
   already cleared MIN_ROLE rather than an open, unbounded query-key space.
3. Public reliability (GET /_status/public, gated on PUBLIC_RELIABILITY):
   uptime, incident, change, and Spot-warning history only, computed purely
   from CloudWatch/Logs with instance detail redacted -- see reliability(),
   incidents(), changes(), interruptions(), and public_response(). No Gramps Web dependency, which is
   what lets it render while the app itself is down. Matched against the raw
   path before the trailing-slash normalization responsibility 2 uses, so
   /_status/public/ can never widen into it; 404s having made zero AWS calls
   when the feature is off.

reliability() is shared verbatim by responsibilities 2 and 3 (see RANGES):
both routes ship the same five-range payload (24h/7d/30d/90d/1y), so the
public and authenticated pages never disagree about uptime. 1y is also this
design's practical ceiling, chosen short of the true one: CloudWatch retains
1-hour-and-coarser metric rollups for 455 days (the tier every Period>=3600
query here draws from), so this Lambda could in principle stretch to ~455
days without new infrastructure, but 365 reads as an honest "a year of
history" cut rather than an arbitrary one. Past 455 days CloudWatch has
nothing left to query at any period; a genuinely multi-year range would need
this Lambda to persist its own monthly rollups (S3 or DynamoDB) --
deliberately not built, since a year of reliability history already makes
the point this page exists to make. /_status/series' own SERIES_MAX_AGE_DAYS
clamp uses this same 455-day ceiling for `end`, not the 365-day one -- a
panned window still names a RANGES/CHART_RANGES span, but its *end* may
legally sit anywhere CloudWatch still has data.

DB/tree data is NOT handled here -- the page itself calls GET /api/metadata/
directly against the site's own origin, same-origin, using the visitor's own
bearer token, to read the Gramps/API version strings shown in Deployment's
Container image block. This Lambda never touches tree data.
"""

import collections
import concurrent.futures
import datetime
import json
import os
import time
import urllib.error
import urllib.request

import boto3
from botocore.config import Config

SITE_URL = os.environ["SITE_URL"]
MIN_ROLE = os.environ["MIN_ROLE"]
ASG_NAME = os.environ["ASG_NAME"]
CODEDEPLOY_APP_NAME = os.environ["CODEDEPLOY_APP_NAME"]
CODEDEPLOY_DEPLOYMENT_GROUP = os.environ["CODEDEPLOY_DEPLOYMENT_GROUP"]
# Defined once in modules/compute (deliberate_deployment_creators); excludes the
# deployments the ASG creates for every instance it launches, which are
# consequences of an outage rather than maintenance.
DELIBERATE_DEPLOYMENT_CREATORS = set(
    os.environ["DELIBERATE_DEPLOYMENT_CREATORS"].split(",")
)
CODEPIPELINE_NAME = os.environ["CODEPIPELINE_NAME"]
SOURCE_REPO = os.environ["SOURCE_REPO"]
ECR_REPO_NAME = os.environ["ECR_REPO_NAME"]
EBS_VOLUME_ID = os.environ.get("EBS_VOLUME_ID", "")
MEDIA_BUCKET_NAME = os.environ["MEDIA_BUCKET_NAME"]
BACKUP_VAULT_NAME = os.environ.get("BACKUP_VAULT_NAME", "")
BACKUP_MODE = os.environ.get("BACKUP_MODE", "")
BACKUP_SCHEDULE = os.environ.get("BACKUP_SCHEDULE", "")
BACKUP_RETENTION_DAYS = os.environ.get("BACKUP_RETENTION_DAYS", "")
BACKUP_RESOURCE_COUNT = os.environ.get("BACKUP_RESOURCE_COUNT", "")
BACKUP_REMOTE_RETENTION_DAYS = os.environ.get("BACKUP_REMOTE_RETENTION_DAYS", "")
BACKUP_REGION = os.environ.get("BACKUP_REGION", "")
BACKUP_COPY_VAULT_ARN = os.environ.get("BACKUP_COPY_VAULT_ARN", "")
BACKUP_DEST_READER_ROLE_ARN = os.environ.get("BACKUP_DEST_READER_ROLE_ARN", "")
SPOT_ENABLED = os.environ.get("SPOT_ENABLED", "false")
LLM_ENABLED = os.environ.get("LLM_ENABLED", "false")
LLM_REGION = os.environ.get("LLM_REGION", "")
LLM_MODEL_ID = os.environ.get("LLM_MODEL_ID", "")
LLM_MAX_REQUESTS = os.environ.get("LLM_MAX_REQUESTS", "")
LLM_MAX_TOKENS = os.environ.get("LLM_MAX_TOKENS", "")
LLM_MAX_CONTEXT_LENGTH = os.environ.get("LLM_MAX_CONTEXT_LENGTH", "")
EPISODES_LOG_GROUP = os.environ["EPISODES_LOG_GROUP"]
EPISODES_LOG_STREAM = os.environ["EPISODES_LOG_STREAM"]
CHANGES_LOG_STREAM = os.environ["CHANGES_LOG_STREAM"]
SPOT_INTERRUPTIONS_LOG_GROUP = os.environ["SPOT_INTERRUPTIONS_LOG_GROUP"]
SITEUP_METRIC_NAMESPACE = os.environ["SITEUP_METRIC_NAMESPACE"]
GRAMPS_WEB_VERSION = os.environ.get("GRAMPS_WEB_VERSION", "")
MONTHLY_BUDGET_USD = os.environ.get("MONTHLY_BUDGET_USD", "")
COST_ENABLED = os.environ.get("COST_ENABLED", "false")
HOST_METRICS_ENABLED = os.environ.get("HOST_METRICS_ENABLED", "false")
VOLUME_METRICS_ENABLED = os.environ.get("VOLUME_METRICS_ENABLED", "false")
PUBLIC_RELIABILITY = os.environ.get("PUBLIC_RELIABILITY", "false")

AUTH_TIMEOUT_S = 4

# Reserved off context.get_remaining_time_in_millis() as the deadline for the
# panel fan-out (see collect_status()), so serializing and returning the
# response always fits inside whatever budget main.tf's Lambda timeout leaves.
SERIALIZATION_RESERVE_S = 2

# Upstream's ladder (gramps-web-api). "nobody" is not a real Gramps Web role --
# it maps one past ADMIN so min_role = "nobody" can never be satisfied, which
# is what makes it a valid runtime lock (page deployed, permanently
# inaccessible) distinct from status.enabled = false (page not deployed).
ROLES = {
    "disabled": -1,
    "unconfirmed": -2,
    "guest": 0,
    "member": 1,
    "contributor": 2,
    "editor": 3,
    "owner": 4,
    "admin": 5,
    "nobody": 6,
}
ROLE_NAMES = {v: k for k, v in ROLES.items()}

# SLO thresholds for strip-cell coloring, hoisted here out of the frontend's
# cellClass() (build/web/src/status/panels/Reliability.tsx). A Lambda response
# is the only channel between this module and the browser -- unlike two
# functions sharing one Python module, "one place" for a constant used on both
# sides of that boundary means "the value the server sends," so these ship
# inside reliability()'s payload and the frontend reads them from there instead
# of hardcoding its own copy.
SLO_GOOD_THRESHOLD = 0.999
SLO_WARN_THRESHOLD = 0.95

# Every reliability tile, on every range, is rounded and shown to the same
# precision: three places is exactly five nines (99.999%), the finest any
# range's SLO band actually distinguishes, so a shorter, sparser-sampled
# range (24h) is not given a false extra digit of confidence just because a
# wider one (1y) could support one. Shipped once at the payload's top level
# (reliability.decimals) rather than per range -- see reliability() -- since
# it is one constant, not five. The tile's own hover-only measurement-floor
# figure (r.checks in the frontend) already carries the honest per-range
# precision caveat this replaces.
UPTIME_DECIMALS = 3

# Range table for the reliability strip, shared verbatim by /_status/data and
# /_status/public (see reliability()) so the operator and public pages can
# never disagree about uptime. Each entry: the CloudWatch query it draws from
# (period_s, query_days -- queries are deduplicated by this pair, so 30d/90d/
# 1y share one actual GetMetricData call), the display window (window_days),
# the fixed cell count the strip renders for it regardless of how much of
# that window CloudWatch actually has data for (cells), and the width of each
# cell in seconds (cell_s). 24h and 7d get their own finer-grained queries so
# their uptime figures aren't blind to sub-hour outages (see
# weighted_uptime()'s boundary-fraction comment); 1y collapses the shared
# 365-day daily query into 52 weekly cells so the strip stays legible on a
# phone (365 daily cells would be sub-pixel). The strip span is cells *
# cell_s, which need not equal window_days -- 1y's is 364d against a 365d
# rolling tile, since 52 whole 7-day cells is the closest calendar-aligned
# fit under a 365-day window. Order here is render order: both the
# percentage tiles and the range-selector buttons on the page follow it.
RANGES = {
    "24h": {
        "period_s": 300,
        "query_days": 1,
        "window_days": 1,
        "cells": 24,
        "cell_s": 3600,
    },
    "7d": {
        "period_s": 3600,
        "query_days": 7,
        "window_days": 7,
        "cells": 28,
        "cell_s": 21600,
    },
    "30d": {
        "period_s": 86400,
        "query_days": 365,
        "window_days": 30,
        "cells": 30,
        "cell_s": 86400,
    },
    "90d": {
        "period_s": 86400,
        "query_days": 365,
        "window_days": 90,
        "cells": 90,
        "cell_s": 86400,
    },
    "1y": {
        "period_s": 86400,
        "query_days": 365,
        "window_days": 365,
        "cells": 52,
        "cell_s": 604800,
    },
}

# Same five keys as RANGES, own shape, shared by host_metrics() and
# assistant(): both panels chart plain gauges/counters rather than
# RANGES' sample-weighted uptime ratios, so one bucket width per range is
# the whole contract -- period_s == cell_s, which keeps bucket_series()
# (last-wins, not averaging) usable unchanged, since a bucket must map to
# exactly one CloudWatch datapoint. 30d/90d/1y share period_s=86400 and so
# collapse to one shared GetMetricData call in both functions below (see
# each function's query_cache closure), the same dedup idiom RANGES' query()
# uses, keyed here by period_s alone since neither panel has a second axis
# (RANGES' query_days) to key on.
CHART_RANGES = {
    "24h": {"period_s": 1800, "cells": 48},  # unchanged resolution
    "7d": {"period_s": 3600, "cells": 168},
    "30d": {"period_s": 86400, "cells": 30},
    "90d": {"period_s": 86400, "cells": 90},
    "1y": {"period_s": 86400, "cells": 365},
}

# Matches RANGES' longest window so the incidents table is never quietly
# missing older episodes that the 1y uptime number already reflects.
INCIDENTS_LOOKBACK_DAYS = 365

# A change counts as an outage when an episode overlaps its [start, at] span
# within this slack. Episode edges are probe resolution (the first failing
# minute, floored), so an outage that began with the change can read up to a
# minute early, and one that ended with it up to a minute late; 90 s adds half
# a minute for the offset between the change's own timestamps and the probe.
CHANGE_OUTAGE_SLACK_S = 90

# Every AWS call this module makes goes through a client bound to this: the
# botocore defaults (60s read / 60s connect, 3 attempts) let one stalled call
# outlive the whole Lambda budget, which is how a single slow branch turned
# into a 502 (see the module docstring's link to the CloudWatch evidence).
BOTO_CONFIG = Config(
    connect_timeout=3, read_timeout=8, retries={"max_attempts": 2, "mode": "standard"}
)

cloudwatch = boto3.client("cloudwatch", config=BOTO_CONFIG)
ec2 = boto3.client("ec2", config=BOTO_CONFIG)
autoscaling = boto3.client("autoscaling", config=BOTO_CONFIG)
codedeploy = boto3.client("codedeploy", config=BOTO_CONFIG)
codepipeline = boto3.client("codepipeline", config=BOTO_CONFIG)
ecr = boto3.client("ecr", config=BOTO_CONFIG)
logs = boto3.client("logs", config=BOTO_CONFIG)
backup_client = boto3.client("backup", config=BOTO_CONFIG)

# AWS/Bedrock metrics publish in the invocation region, which need not be this
# Lambda's own region (see llm_region in variables.tf).
llm_cloudwatch = (
    boto3.client("cloudwatch", region_name=LLM_REGION, config=BOTO_CONFIG)
    if LLM_ENABLED == "true" and LLM_REGION
    else None
)

# Cost Explorer is always reached via us-east-1 regardless of workload region.
ce = (
    boto3.client("ce", region_name="us-east-1", config=BOTO_CONFIG)
    if COST_ENABLED == "true"
    else None
)

# Module-level (outside-handler) cache for the cost panel: Cost Explorer bills
# $0.01/request, so a warm container reuses the last result for an hour rather
# than re-billing every page load. Cold starts pay the $0.01 again; that's the
# tradeoff of not paying for a database this page doesn't otherwise need.
COST_CACHE_TTL_S = 60 * 60
_cost_cache = {"data": None, "fetched_at": 0.0}

# Public payload cache-control. The split between the two matters for the
# kill switch: flipping status.public_reliability off invalidates nothing at
# CloudFront, so a flat max-age=300 would leave browsers still serving the
# old response for up to 5 minutes after the feature was turned off; capping
# the browser side at 60s while letting the shared edge cache (s-maxage) run
# longer keeps that window short without refetching from origin on every
# visit. Never no-store: the CachingOptimized policy on this behavior has
# min_ttl=1, so no-store is not honored here anyway.
PUBLIC_CACHE_CONTROL_HEALTHY = "public, s-maxage=300, max-age=60"
PUBLIC_CACHE_CONTROL_DEGRADED = "public, max-age=10"

# Module-level warm cache for the public payload, mirroring _cost_cache above.
# This is an abuse bound, not a cost optimization -- CloudFront already caps
# origin fetches for this behavior at roughly one per regional edge cache per
# s-maxage=300s window on the honest path, so this cache's job is bounding
# what a flood that bypasses or races the edge cache can do to this Lambda's
# concurrency (see reserved_concurrent_executions in main.tf) and to the AWS
# APIs behind it, not saving money on an already-cheap call.
PUBLIC_CACHE_TTL_S = 60
_public_cache = {"data": None, "fetched_at": 0.0}

# Warm cache for the panel payload collect_status() assembles, mirroring
# _cost_cache/_public_cache above. The panels are identical for every caller
# (only caller_role differs, stitched on in data_response()), so a hit here
# skips the whole fan-out. This is what makes the deadline in collect_status()
# stop mattering in practice: most requests never reach it.
DATA_CACHE_TTL_S = 30
_data_cache = {"data": None, "fetched_at": 0.0}

# CloudWatch's own retention ceiling for hourly-and-coarser rollups (see the
# module docstring) -- the hard bound on how far `end` may reach back,
# independent of any individual range's own window_days/RANGES entry.
SERIES_MAX_AGE_DAYS = 455

# A bounded LRU, not a TTL-only cache like _data_cache/_public_cache above:
# a panned window's `end` is a distinct, immutable point in the past (unlike
# the live payload, which is always "now"), so the natural cache key is
# unbounded and must be capped by eviction, not just expiry. 8 entries is
# enough to hold a few minutes of one operator scrubbing back and forth
# without thrashing. 600s -- 20x DATA_CACHE_TTL_S -- because a completed
# window's data never changes; the only thing that can invalidate an entry
# is CloudWatch backfilling a late datapoint, which this page has never
# observed happen at the period_s granularities RANGES/CHART_RANGES use.
SERIES_CACHE_TTL_S = 600
SERIES_CACHE_MAX_ENTRIES = 8
_series_cache = collections.OrderedDict()


def handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")
    headers = event.get("headers") or {}

    if method != "GET":
        return respond(404, {"error": "not found"})

    # Matched against the RAW path, before the trailing-slash normalization
    # below: /_status/public/ must NOT fall into this branch (rstrip would
    # otherwise fold it into the exact same path as /_status/public itself,
    # serving the full public payload off a trailing-slash request), so it
    # 404s below having made zero AWS calls, independent of whatever
    # CloudFront behavior actually routed it here.
    raw = event.get("rawPath") or ""
    if raw == "/_status/public":
        return public_response(context)

    path = raw.rstrip("/") or "/"
    if path == "/_status/data":
        return data_response(headers, context)
    if path == "/_status/series":
        return series_response(headers, event.get("queryStringParameters") or {})
    return respond(404, {"error": "not found"})


def respond(status_code, body, cache_control="no-store"):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json", "Cache-Control": cache_control},
        "body": json.dumps(body),
    }


# --- auth -------------------------------------------------------------------


def require_role(headers):
    """Shared by data_response() and series_response(): both routes carry
    the identical two-step gate (a valid token, then MIN_ROLE), and neither
    goes further without it. Returns (role, role_name) on success, or an
    already-built error response to return verbatim -- distinguished by
    which slot is None, matching authenticate()'s own (None, None)-on-
    failure contract.
    """
    role, role_name = authenticate(headers)
    if role is None:
        return None, respond(401, {"error": "unauthorized"})
    if role < ROLES.get(MIN_ROLE, ROLES["nobody"]):
        return None, respond(403, {"error": "forbidden", "required_role": MIN_ROLE})
    return (role, role_name), None


def data_response(headers, context):
    auth, err = require_role(headers)
    if err is not None:
        return err
    _role, role_name = auth

    now_ts = time.time()
    cached = _data_cache["data"]
    if cached is not None and (now_ts - _data_cache["fetched_at"]) < DATA_CACHE_TTL_S:
        panels = cached
    else:
        panels = collect_status(context)
        # Never cache a degraded response -- a timed-out or failed branch is
        # exactly the case where the next caller should get a fresh attempt,
        # not the same failure replayed for up to DATA_CACHE_TTL_S.
        if not any(is_error(v) for v in panels.values()):
            _data_cache["data"] = panels
            _data_cache["fetched_at"] = now_ts

    data = {
        "min_role": MIN_ROLE,
        "caller_role": role_name,
        "gramps_web_version": GRAMPS_WEB_VERSION,
        "source_repo": SOURCE_REPO,
        "spot_enabled": SPOT_ENABLED == "true",
    }
    data.update(panels)
    return respond(200, data)


def series_response(headers, query):
    """GET /_status/series?panel=<>&range=<>&end=<iso8601> -- one panel, one
    range, ending at an arbitrary past instant instead of the live edge. See
    the module docstring's responsibility 2 for why this exists and which
    three panels it covers.
    """
    _auth, err = require_role(headers)
    if err is not None:
        return err

    panel_name = query.get("panel")
    # (function, "is this panel's own toggle on") -- None means always on,
    # matching collect_status()'s unconditional branches.
    panel_funcs = {
        "reliability": (reliability, True),
        "host_metrics": (host_metrics, HOST_METRICS_ENABLED == "true"),
        "assistant": (assistant, LLM_ENABLED == "true"),
    }
    if panel_name not in panel_funcs:
        return respond(400, {"error": f"panel must be one of {sorted(panel_funcs)}"})
    fn, enabled = panel_funcs[panel_name]
    if not enabled:
        return respond(404, {"error": "not found"})

    # Validated against RANGES, not CHART_RANGES, even for host_metrics/
    # assistant -- CHART_RANGES' own docstring declares the two share the
    # same five keys by design, so one check covers all three panels.
    range_key = query.get("range")
    if range_key not in RANGES:
        return respond(400, {"error": f"range must be one of {list(RANGES)}"})

    end_raw = query.get("end")
    if not end_raw:
        return respond(400, {"error": "end is required"})
    try:
        end = datetime.datetime.fromisoformat(end_raw)
        if end.tzinfo is None:
            end = end.replace(tzinfo=datetime.UTC)
        else:
            end = end.astimezone(datetime.UTC)
    except ValueError:
        return respond(400, {"error": "end must be a valid ISO 8601 timestamp"})

    now = datetime.datetime.now(datetime.UTC)
    if end > now:
        return respond(400, {"error": "end may not be in the future"})
    if end < now - datetime.timedelta(days=SERIES_MAX_AGE_DAYS):
        return respond(
            400,
            {
                "error": f"end may not be more than {SERIES_MAX_AGE_DAYS} days in the past"
            },
        )

    cache_key = (panel_name, range_key, iso(end))
    cached = _series_cache.get(cache_key)
    now_ts = time.time()
    if cached is not None and (now_ts - cached["fetched_at"]) < SERIES_CACHE_TTL_S:
        _series_cache.move_to_end(cache_key)
        panel_data = cached["data"]
    else:
        panel_data = safe_section(f"series:{panel_name}", fn, end, [range_key])
        if not is_error(panel_data):
            _series_cache[cache_key] = {"data": panel_data, "fetched_at": now_ts}
            _series_cache.move_to_end(cache_key)
            while len(_series_cache) > SERIES_CACHE_MAX_ENTRIES:
                _series_cache.popitem(last=False)

    return respond(
        200,
        {"panel": panel_name, "range": range_key, "end": iso(end), "data": panel_data},
    )


def authenticate(headers):
    """Resolve the caller's Gramps Web role from their token, or (None, None).

    The token travels in X-Gramps-Token, not Authorization: CloudFront
    overwrites Authorization with its own SigV4 signature when OAC-signing
    this request to the Lambda Function URL, so by the time it reaches here
    the browser's real Authorization header is gone. X-Gramps-Token survives
    (forwarded verbatim by the origin request policy in edge/status.tf) and
    is translated back into a normal `Authorization: Bearer <token>` header
    for the outbound call below -- a different hop, no CloudFront involved,
    so the collision doesn't recur.
    """
    token = headers.get("x-gramps-token")
    if not token:
        return None, None

    req = urllib.request.Request(
        f"{SITE_URL}/api/users/-/",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=AUTH_TIMEOUT_S) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except (
        urllib.error.HTTPError,
        urllib.error.URLError,
        TimeoutError,
        ValueError,
        OSError,
    ) as e:
        print(json.dumps({"auth_failed": f"{type(e).__name__}: {e}"}))
        return None, None

    role = body.get("role") if isinstance(body, dict) else None
    if not isinstance(role, int):
        print(
            json.dumps(
                {"auth_failed": "missing or non-int role in /api/users/-/ response"}
            )
        )
        return None, None
    return role, ROLE_NAMES.get(role, str(role))


# --- data ---------------------------------------------------------------------


def safe_section(name, fn, *args):
    start = time.monotonic()
    try:
        return fn(*args)
    except Exception as e:  # one panel's AWS failure must not sink the page
        print(json.dumps({"section_failed": name, "error": f"{type(e).__name__}: {e}"}))
        return {"error": f"{type(e).__name__}: {e}"}
    finally:
        print(
            json.dumps(
                {"section": name, "ms": round((time.monotonic() - start) * 1000)}
            )
        )


def is_error(v):
    """True for a branch result shaped like safe_section's own failure output
    ({"error": ...}), which is also the shape a handful of panels return for
    their own soft failures (host()'s missing ASG, image()'s missing AMI, the
    "timed out" marker below). Used to decide what is safe to cache.
    """
    return isinstance(v, dict) and "error" in v


def collect_status(context):
    """Fan out every panel branch and return the results keyed by name --
    exactly the payload data_response() caches in _data_cache, with no
    caller-specific fields (those are stitched on by the caller).

    (name, fn) pairs, one per worker thread. host_image_storage keeps the
    image panel's dependency on host's ami_id, and the storage panel's
    dependency on host's root_volume_id, inside a single sequential branch
    rather than wiring future-to-future dependencies; every other branch is
    independent of the rest. 10 workers cover the panel count with room to
    grow; there is no per-branch ordering to preserve since results are
    collected into a dict keyed by name.

    The whole fan-out is bounded by context.get_remaining_time_in_millis(),
    less SERIALIZATION_RESERVE_S: a branch still running at the deadline is
    abandoned (its thread keeps running to completion, but nothing waits on
    it) and reported as {"error": "timed out"}, the same shape safe_section's
    own except branch produces, so the frontend needs no separate handling.
    """
    branches = [
        ("reliability", reliability),
        ("incidents", incidents),
        ("changes", changes),
        ("interruptions", interruptions),
        ("host_image_storage", host_image_storage),
        ("deployment", deployment),
    ]
    if BACKUP_VAULT_NAME:
        branches.append(("backups", backups))
    if LLM_ENABLED == "true":
        branches.append(("assistant", assistant))
    if COST_ENABLED == "true":
        branches.append(("cost", cost))
    if HOST_METRICS_ENABLED == "true":
        branches.append(("host_metrics", host_metrics))

    pool = concurrent.futures.ThreadPoolExecutor(max_workers=10)
    try:
        futures = {name: pool.submit(safe_section, name, fn) for name, fn in branches}
        deadline_s = max(
            0.0, context.get_remaining_time_in_millis() / 1000 - SERIALIZATION_RESERVE_S
        )
        done, _ = concurrent.futures.wait(futures.values(), timeout=deadline_s)
        results = {
            name: (future.result() if future in done else {"error": "timed out"})
            for name, future in futures.items()
        }
    finally:
        # wait=False: a branch past the deadline is abandoned, not waited on
        # again -- that would defeat the point of the deadline above.
        pool.shutdown(wait=False, cancel_futures=True)

    hist = results.pop("host_image_storage")
    if isinstance(hist, dict) and "host" in hist:
        results["host"] = hist["host"]
        results["image"] = hist["image"]
        results["storage"] = hist["storage"]
    else:
        # host_image_storage() itself never raises (it wraps host(), image(),
        # and storage() individually below), but safe_section's except
        # branch (or a timeout) is the fallback if it somehow does.
        results["host"] = results["image"] = results["storage"] = hist
    return results


# --- public reliability -------------------------------------------------------


def public_response(context):
    """/_status/public: reliability, incidents, changes, and Spot warnings only,
    redacted, unauthenticated.

    See the module docstring (responsibility 3) for why this exists and how
    it is routed; see PUBLIC_CACHE_TTL_S above for why it also carries its
    own warm cache distinct from the operator page's per-panel caches.
    """
    if PUBLIC_RELIABILITY != "true":
        return respond(404, {"error": "not found"})

    now_ts = time.time()
    cached = _public_cache["data"]
    if (
        cached is not None
        and (now_ts - _public_cache["fetched_at"]) < PUBLIC_CACHE_TTL_S
    ):
        return respond(200, cached, cache_control=PUBLIC_CACHE_CONTROL_HEALTHY)

    # Same deadline-bounded pattern as collect_status(), and for the same
    # reason: these are unauthenticated AWS calls with no caller to blame a
    # hang on.
    sections = public_sections()
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=len(sections))
    try:
        futures = {
            name: pool.submit(safe_section, name, fn)
            for name, (fn, _) in sections.items()
        }
        deadline_s = max(
            0.0, context.get_remaining_time_in_millis() / 1000 - SERIALIZATION_RESERVE_S
        )
        done, _ = concurrent.futures.wait(futures.values(), timeout=deadline_s)
        results = {
            name: future.result() if future in done else {"error": "timed out"}
            for name, future in futures.items()
        }
    finally:
        pool.shutdown(wait=False, cancel_futures=True)

    # A raw exception string is fine on the operator page (safe_section's
    # normal contract) but not here: this response can sit in CloudFront for
    # minutes and be read by anyone, so any AWS-supplied detail is replaced
    # with a fixed, uninformative message before it is ever cached or sent.
    payload = {
        name: {"error": "unavailable"}
        if is_error(results[name])
        else redact(results[name])
        for name, (_, redact) in sections.items()
    }
    payload["spot_enabled"] = SPOT_ENABLED == "true"

    if any(is_error(v) for v in payload.values()):
        # Never cache a degraded response, in the warm cache or at
        # CloudFront: max-age=10 (not no-store -- CachingOptimized's
        # min_ttl=1 means no-store is not honored on this behavior) bounds
        # how long a transient AWS throttle stays visible to the public.
        return respond(200, payload, cache_control=PUBLIC_CACHE_CONTROL_DEGRADED)

    _public_cache["data"] = payload
    _public_cache["fetched_at"] = now_ts
    return respond(200, payload, cache_control=PUBLIC_CACHE_CONTROL_HEALTHY)


# Redaction is an allowlist, not a blocklist: each producer emits more than is
# ever republished here, and the rest is dropped at the source, not hidden in
# the UI. Episode cause and planned are a deliberate disclosure: they say
# production runs on preemptible capacity and gets rightsized and redeployed
# automatically, which makes the cost/reliability tradeoff legible. The same
# goes for a change's kind, creator, and outcome, and for the time of each
# Spot warning; ids, descriptions, and instance details stay private. Only
# deliberate changes are listed: the deployments Auto Scaling creates for each
# launched instance are consequences, not changes.


def keep_fields(*fields):
    return lambda items: [{f: item.get(f) for f in fields} for item in items]


def public_sections():
    """name -> (producer, redaction), in payload order."""
    return {
        "reliability": (reliability, lambda value: value),
        "incidents": (
            incidents,
            keep_fields("started", "duration_s", "cause", "planned"),
        ),
        "changes": (
            changes,
            lambda items: keep_fields("at", "kind", "creator", "outcome")(
                [c for c in items if is_deliberate_change(c)]
            ),
        ),
        "interruptions": (interruptions, keep_fields("time")),
    }


# --- reliability --------------------------------------------------------------


def floor_utc(dt, width_s):
    """Floor `dt` down to the nearest multiple of `width_s` seconds since the
    Unix epoch. Takes seconds, not a timedelta, so no call site can pass the
    wrong type (a timedelta div silently truncates instead of raising).
    """
    epoch = datetime.datetime(1970, 1, 1, tzinfo=datetime.UTC)
    width = datetime.timedelta(seconds=width_s)
    return epoch + ((dt - epoch) // width) * width


def bucket_series(timestamps, values, strip_start, period_td, count):
    """`count` equal-width (`period_td`-wide) buckets starting at
    `strip_start`, floor-division bucketing -- the same join grid_cells()
    uses (see its docstring on why floor division, not int()), shared here
    by host_metrics() and assistant() so both panels' charts join CloudWatch
    responses back the same, alignment-tolerant way. A datapoint whose
    bucket falls outside [0, count) (the one period of slack a caller's
    StartTime may include) is silently dropped rather than smeared into an
    edge bucket. Returns raw values, oldest to newest -- rounding/casting is
    left to the caller, since HOST_METRIC_SPECS wants floats to 1 decimal
    and assistant()'s token counts want ints.
    """
    series = [None] * count
    for ts, v in zip(timestamps, values):
        idx = (ts - strip_start) // period_td
        if 0 <= idx < count:
            series[idx] = v
    return series


def reliability(now=None, keys=None):
    """now/keys: /_status/series' hooks for panning a single range to a past
    `end` instead of the live edge (see the module docstring's responsibility
    2). now=None/keys=None reproduce /_status/data's live, all-five-ranges
    call exactly -- every existing caller and test is this default. `keys`
    also bounds excl_windows' own lookback to the widest requested range's
    window_days rather than the flat INCIDENTS_LOOKBACK_DAYS, so panning a
    24h window doesn't pull a year of episodes/CodeDeploy history to exclude
    minutes it isn't even querying.
    """
    now = now or datetime.datetime.now(datetime.UTC)
    keys = keys or list(RANGES)
    excl_days = max(RANGES[k]["window_days"] for k in keys)
    excl_windows = planned_windows(days=excl_days, now=now)

    # Queries are deduplicated by (period_s, query_days): 30d/90d/1y all name
    # the same pair in RANGES and so share the one GetMetricData call below
    # rather than issuing three identical ones. Floored to period_s only --
    # *not* to a cell's own width, which would break this dedup (30d/90d/1y
    # have different cell_s but the same (period_s, query_days)). Every
    # floored StartTime here is a multiple of both 60 and 300, so CloudWatch's
    # own StartTime flooring (to the nearest multiple of Period) is a no-op
    # regardless of which Period a given query uses -- this fix is safe
    # rather than lucky. The extra period of slack subtracted below costs one
    # datapoint and makes a wrongly-gray leading cell structurally
    # impossible (24h otherwise has exactly zero margin when `now` falls
    # exactly on the hour).
    query_cache = {}

    def query(period_s, query_days):
        key = (period_s, query_days)
        if key not in query_cache:
            qstart = floor_utc(
                now - datetime.timedelta(days=query_days), period_s
            ) - datetime.timedelta(seconds=period_s)
            query_cache[key] = reliability_window(qstart, now, period_s)
        return query_cache[key]

    ranges = {}
    for key in keys:
        spec = RANGES[key]
        series = query(spec["period_s"], spec["query_days"])
        cell_s = spec["cell_s"]
        # Cell boundaries are calendar-aligned, not query-aligned: epoch-
        # flooring to a period longer than a day would land on whatever
        # weekday 1970-01-01 was (a Thursday) rather than today, so `align`
        # caps at one day and 1y's 7-day cells instead slide forward daily as
        # day-anchored spans (see cell_label()).
        align = min(cell_s, 86400)
        strip_end = floor_utc(now, align) + datetime.timedelta(seconds=align)
        strip_start = strip_end - spec["cells"] * datetime.timedelta(seconds=cell_s)
        window_start = now - datetime.timedelta(days=spec["window_days"])
        cells = grid_cells(series, strip_start, cell_s, spec["cells"])
        # The tile's measurement floor: how many checks its own rolling
        # window (window_days -- not the strip's cells * cell_s span, which
        # for 1y is a day short of it; see the module docstring) is worth,
        # scaled from grid_cells()'s own per-cell rate inference rather than
        # a hardcoded cadence, so the figure the frontend puts in the tile's
        # title attribute (e.g. "+/-0.0008% * 129,600 checks") stays truthful
        # under any cadence. None when grid_cells() found no complete bucket
        # to infer a rate from (a brand-new range), so the frontend omits the
        # figure rather than claiming a false precision.
        cell_rate = cells[0]["expected_samples"] if cells else None
        checks = (
            round(cell_rate * spec["window_days"] * 86400 / cell_s)
            if cell_rate
            else None
        )
        uptime = weighted_uptime(series, window_start, now, spec["period_s"])
        # Same series, same window -- the only difference is that downtime
        # falling inside a planned=true episode (a deploy, a rightsize
        # replacement, ...; see availability.py's planned flag) is dropped
        # from the ratio's denominator rather than counted as down (see
        # weighted_uptime's docstring). Lets the status page show "what my
        # uptime would be if planned maintenance didn't count against it" as
        # one of two numbers the reader toggles between, without changing
        # what "uptime" means.
        uptime_excl_planned = weighted_uptime(
            series, window_start, now, spec["period_s"], excl_windows
        )
        # Sample counts (the weighting the line above just used) stop here --
        # they never enter the latency list, so /_status/public does not start
        # disclosing traffic volume just because public_reliability is also on.
        lat = latency_cells(series, strip_start, cell_s, spec["cells"])
        ranges[key] = {
            # weighted_uptime() itself returns full precision; rounding is
            # deferred to here so it happens exactly once, at UPTIME_DECIMALS
            # -- the same precision for every range, shipped once below
            # rather than repeated per range.
            "uptime": round(uptime, UPTIME_DECIMALS) if uptime is not None else None,
            "uptime_excl_planned": round(uptime_excl_planned, UPTIME_DECIMALS)
            if uptime_excl_planned is not None
            else None,
            "cells": cells,
            "latency": {
                "probe": [{"p50": b["p50"], "p90": b["p90"]} for b in lat],
            },
            "cell_s": cell_s,
            "checks": checks,
        }

    return {
        "ranges": ranges,
        "slo_good_threshold": SLO_GOOD_THRESHOLD,
        "slo_warn_threshold": SLO_WARN_THRESHOLD,
        "decimals": UPTIME_DECIMALS,
    }


def weighted_uptime(series, start, end, period_s, exclude_windows=None):
    """Sample-weighted uptime % over [start, end) from raw (ts, avg, samples,
    p50, p90) datapoints, each spanning [ts, ts+period) -- the latency fields
    ride along on every series (see reliability_window()) but are irrelevant
    to uptime and ignored here.

    A datapoint whose own bucket straddles start or end -- only ever the
    oldest and newest bucket of the window -- is weighted by the fraction of
    its period that overlaps the window, rather than the whole-bucket
    ts >= cutoff cutoff the original 90d-only code used: that dropped the
    boundary bucket entirely, silently shrinking the window by up to one
    period (harmless at Period=300, but up to a full day at Period=86400).
    Weighting by time-fraction assumes the bucket's real samples are spread
    uniformly across its period -- true enough for a steady 1/minute canary.

    exclude_windows (optional): [(start, end), ...] spans -- planned-outage
    episodes, in practice (see reliability()'s uptime_excl_planned) -- whose
    overlap with a bucket removes that much planned *downtime* from the
    bucket, not planned *time*: the down probes a planned window accounts for
    are dropped from the denominator only, capped at the down probes actually
    observed, so a bucket's average (which is exactly what makes its samples
    non-uniform when the excluded span is why they failed) never needs to be
    assumed uniform for this part. None/[] reproduces the original
    unweighted-by-exclusion behavior exactly.
    """
    period = datetime.timedelta(seconds=period_s)
    weighted, total = 0.0, 0.0
    for ts, avg, samples, *_latency in series:
        if avg is None or not samples:
            continue
        bucket_start, bucket_end = max(ts, start), min(ts + period, end)
        overlap_s = (bucket_end - bucket_start).total_seconds()
        if overlap_s <= 0:
            continue
        fraction = min(1.0, overlap_s / period_s)
        up = avg * samples * fraction
        seen = samples * fraction
        if exclude_windows:
            planned_s = excluded_overlap_s(bucket_start, bucket_end, exclude_windows)
            if planned_s > 0:
                seen -= min(seen - up, planned_s * samples / period_s)
        if seen <= 0:
            continue
        weighted += up
        total += seen
    return 100 * weighted / total if total else None


def excluded_overlap_s(window_start, window_end, exclude_windows):
    """Total seconds of [window_start, window_end) covered by exclude_windows
    ([(start, end), ...], possibly overlapping each other). Windows are
    summed independently rather than merged first -- double-counting any
    overlap between two planned episodes -- which weighted_uptime's min()
    clamp now makes safe: over-subtraction can remove at most the down probes
    actually observed in a bucket, never more.
    """
    total = 0.0
    for w_start, w_end in exclude_windows:
        overlap = min(window_end, w_end) - max(window_start, w_start)
        overlap_s = overlap.total_seconds()
        if overlap_s > 0:
            total += overlap_s
    return total


def planned_windows(days=INCIDENTS_LOOKBACK_DAYS, now=None):
    """[(started, ended), ...] to exclude from uptime_excl_planned, from two
    sources: every planned=true episode in the lookback window (a deploy long
    enough to trip the site_down alarm), plus every CodeDeploy deployment's
    own (createTime, completeTime) window regardless of whether it produced
    an episode. The second source exists because the alarm is 2-of-3
    datapoints at 60s: a deployment blip shorter than that never trips it, so
    no episode is ever written for it, and without this it silently counts as
    unplanned. The two sources can overlap freely -- excluded_overlap_s sums
    windows independently and weighted_uptime's min() clamp bounds
    over-subtraction to the down probes actually observed, so a deployment
    that *did* trip the alarm being counted twice costs nothing.

    now: /_status/series' panning hook (see reliability()'s docstring) --
    both sources' own lookback windows shift with it rather than staying
    anchored to the live edge.
    """
    now = now or datetime.datetime.now(datetime.UTC)
    return episode_windows(days, now) + codedeploy_windows(days, now)


def episode_windows(days, now=None):
    """The episode half of planned_windows() -- see its docstring. Reuses
    incidents() rather than re-deriving episode windows some other way: the
    episode already carries the answer (`planned`, set by availability.py).
    Degrades to [] (nothing excluded, uptime_excl_planned falls back to
    matching uptime) rather than raising: a hiccup here must
    not break the raw uptime numbers this function has always returned.
    """
    try:
        episodes = incidents(days, now)
    except Exception as e:
        print(json.dumps({"planned_windows_failed": f"{type(e).__name__}: {e}"}))
        return []
    windows = []
    for ep in episodes:
        if not ep.get("planned") or not ep.get("started") or not ep.get("ended"):
            continue
        try:
            windows.append((parse_iso(ep["started"]), parse_iso(ep["ended"])))
        except ValueError:
            continue
    return windows


def codedeploy_windows(days, now=None):
    """The CodeDeploy half of planned_windows() -- see its docstring. A
    separate paginated read from deployment()'s: that one only ever inspects
    the 25 most recent deployments, but a year holds far more (76, measured
    live), so a year-wide exclusion can't reuse it. Every status regardless
    of Succeeded/Failed/Stopped counts -- a failed deployment that took the
    site down is still maintenance, and availability.py's own
    classify_cause() already marks such episodes planned, so filtering here
    would contradict the episode source. Filtered by `creator` (see
    DELIBERATE_DEPLOYMENT_CREATORS), not by status. Degrades to [] on
    any failure, same contract as episode_windows().
    """
    try:
        now = now or datetime.datetime.now(datetime.UTC)
        start = now - datetime.timedelta(days=days)
        ids = []
        kwargs = {
            "applicationName": CODEDEPLOY_APP_NAME,
            "deploymentGroupName": CODEDEPLOY_DEPLOYMENT_GROUP,
            "createTimeRange": {"start": start, "end": now},
        }
        while True:
            r = codedeploy.list_deployments(**kwargs)
            ids.extend(r.get("deployments", []))
            token = r.get("nextToken")
            if not token:
                break
            kwargs["nextToken"] = token

        windows = []
        for i in range(0, len(ids), 25):
            details = codedeploy.batch_get_deployments(deploymentIds=ids[i : i + 25])[
                "deploymentsInfo"
            ]
            for d in details:
                if (
                    d.get("createTime")
                    and d.get("completeTime")
                    and d.get("creator") in DELIBERATE_DEPLOYMENT_CREATORS
                ):
                    windows.append((d["createTime"], d["completeTime"]))
        return windows
    except Exception as e:
        print(json.dumps({"codedeploy_windows_failed": f"{type(e).__name__}: {e}"}))
        return []


def parse_iso(ts):
    """Inverse of iso() below: 'YYYY-MM-DDTHH:MM:SSZ' -> aware UTC datetime."""
    return datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=datetime.UTC
    )


def grid_cells(series, start, width, count):
    """`count` equal-width (`width` seconds) buckets starting at `start`,
    independent of the query's own period -- e.g. the 1y range packs the
    same 365 daily datapoints (period 86400s) that 30d/90d also read into 52
    weekly buckets. `end` is deliberately not a parameter: a future-dated
    strip_end must never reach weighted_uptime, whose min(ts + period, end)
    clamp assumes `end` is the *query's* end, not the strip's -- dropping it
    here makes that mixup structurally impossible. Every range keeps this
    same cell count regardless of how much of the window CloudWatch has data
    for: a bucket with no datapoints renders {"avg": None, "samples": 0}
    (the gray "no data" cell) instead of shrinking the array, so a young
    deployment's 90d strip reads as "partially filled in" rather than
    looking like a shorter range.

    `series` entries are reliability_window()'s (ts, avg, samples, p50, p90)
    rows; the latency fields are irrelevant to uptime and ignored here (see
    latency_cells() below for the sibling bucketer that reads them instead).
    """
    width_td = datetime.timedelta(seconds=width)
    now = datetime.datetime.now(datetime.UTC)
    buckets = [
        {
            "start": start + i * width_td,
            "weighted": 0.0,
            "samples": 0,
        }
        for i in range(count)
    ]
    for row in series:
        ts, avg, samples = row[0], row[1], row[2]
        if avg is None or not samples:
            continue
        # Floor division, not int(): int() truncates toward zero, so a
        # datapoint just before `start` (idx == -1) mapped into cell 0
        # instead of being dropped. Floor division makes misalignment fail
        # loudly (idx lands outside [0, count) and is discarded) instead of
        # smearing into cell 0.
        idx = (ts - start) // width_td
        if 0 <= idx < count:
            b = buckets[idx]
            b["weighted"] += avg * samples
            b["samples"] += samples
    # expected_samples is inferred from this call's own complete buckets, so a
    # cadence change is reflected rather than compared against a fixed
    # assumption. "Complete" excludes the trailing partial bucket (its samples
    # count is how far `now` has gotten into a still-filling period, not a
    # rate) and any all-gray no-data bucket. Median, not mean: robust to a
    # minority of degraded buckets (e.g. a canary outage that under-filled one
    # otherwise-complete bucket), and always one of the actually-observed
    # counts rather than an interpolated in-between value. None, not 0, when
    # nothing qualifies (a brand-new range's first cell) -- the frontend's
    # falsy check then skips the checks-scaled downtime estimate instead of
    # dividing by zero.
    complete_samples = sorted(
        b["samples"]
        for b in buckets
        if b["samples"] and not (b["start"] <= now < b["start"] + width_td)
    )
    expected_samples = (
        complete_samples[len(complete_samples) // 2] if complete_samples else None
    )
    return [
        {
            "label": cell_label(b["start"], width),
            "avg": (b["weighted"] / b["samples"]) if b["samples"] else None,
            "samples": b["samples"],
            "partial": b["start"] <= now < b["start"] + width_td,
            "expected_samples": expected_samples,
        }
        for b in buckets
    ]


def latency_cells(series, start, width, count):
    """`count` equal-width buckets of the canary's latency, mirroring
    grid_cells()'s floor-division bucketing and fixed cell count exactly (see
    that docstring) but averaging percentiles instead of weighting an uptime
    ratio: {"p50": <float or None>, "p90": <float or None>} per bucket,
    from the canary's own LatencyMs.

    Averaging per-period percentiles across buckets is an approximation, not
    a re-derived percentile: the mean of several p50s is not the p50 of their
    union (that would need the raw latency samples, which CloudWatch has
    already discarded by the time this reads back p50/p90). Good enough for
    a sparkline's shape; stated here rather than left to look more exact than
    it is.

    That mean is sample-count-weighted, not a plain average of the periods
    that landed in the bucket: a period the canary under-filled (an outage)
    should move a cell less than a full one. A row with no usable count
    (None, or 0) falls back to weight 1.

    A bucket with no latency points at all -- not just a low-traffic one --
    renders None rather than 0 or an interpolated neighbor. This is
    deliberate, not a missing-data gap to paper over: availability.py's
    canary only emits LatencyMs when an HTTP status actually came back, so a
    DNS/TLS/timeout failure produces SiteUp=0 with no matching latency
    datapoint (see reliability_window()). The chart must break its line --
    reading zero would claim an instant response, and interpolating would
    erase the exact moment the strip is showing red.
    """
    width_td = datetime.timedelta(seconds=width)
    buckets = [
        {
            "p50_sum": 0.0,
            "p50_w": 0.0,
            "p90_sum": 0.0,
            "p90_w": 0.0,
        }
        for _ in range(count)
    ]
    for ts, _avg, samples, p50, p90 in series:
        idx = (ts - start) // width_td
        if not (0 <= idx < count):
            continue
        b = buckets[idx]
        weight = samples if samples else 1
        if p50 is not None:
            b["p50_sum"] += p50 * weight
            b["p50_w"] += weight
        if p90 is not None:
            b["p90_sum"] += p90 * weight
            b["p90_w"] += weight
    return [
        {
            "p50": (b["p50_sum"] / b["p50_w"]) if b["p50_w"] else None,
            "p90": (b["p90_sum"] / b["p90_w"]) if b["p90_w"] else None,
        }
        for b in buckets
    ]


def cell_label(start, width_s):
    """Three-way label, server-supplied so the frontend never needs its own
    date-formatting logic for the strip:

    - week-span cells (1y): a plain date range ("2026-07-13 – 2026-07-19"),
      not "week of" -- these are day-anchored 7-day spans that slide forward
      daily (see reliability()'s `align` comment), not calendar weeks.
    - day cells (30d/90d): a calendar date ("2026-07-15").
    - sub-day cells (24h/7d): clock time plus date ("2026-07-15 14:00"),
      since a 6-hour (7d) or 1-hour (24h) cell can cross midnight.
    """
    if width_s >= 604800:
        end_date = (
            (start + datetime.timedelta(seconds=width_s) - datetime.timedelta(days=1))
            .date()
            .isoformat()
        )
        return f"{start.date().isoformat()} – {end_date}"
    if width_s >= 86400:
        return start.date().isoformat()
    return start.strftime("%Y-%m-%d %H:%M")


def reliability_window(start, end, period):
    """[(timestamp, average, sample_count, p50, p90), ...] over [start, end],
    one row per bucket at `period` resolution.

    LatencyMs rides along on the same call as SiteUp (two more
    MetricDataQueries, ReturnData still costing nothing extra) so latency
    arrives for free everywhere this function's result is already cached:
    reliability()'s query_cache dedups by (period_s, query_days), and
    30d/90d/1y already share one call for uptime, so they share it for
    latency too -- this is why merging Latency into Reliability adds zero
    GetMetricData calls.

    The timestamp union driving the returned rows is avg/cnt (SiteUp), not
    p50/p90: a probe that failed before an HTTP status came back has a SiteUp
    point and no LatencyMs point, and that row must still exist so
    weighted_uptime()/grid_cells() see it -- p50_by_ts.get(ts)/
    p90_by_ts.get(ts) then correctly fall through to None instead of a
    KeyError or a fabricated zero (see latency_cells()'s docstring on why
    that gap matters).
    """
    queries = [
        {
            "Id": "avg",
            "MetricStat": {
                "Metric": {
                    "Namespace": SITEUP_METRIC_NAMESPACE,
                    "MetricName": "SiteUp",
                },
                "Period": period,
                "Stat": "Average",
            },
            "ReturnData": True,
        },
        {
            "Id": "cnt",
            "MetricStat": {
                "Metric": {
                    "Namespace": SITEUP_METRIC_NAMESPACE,
                    "MetricName": "SiteUp",
                },
                "Period": period,
                "Stat": "SampleCount",
            },
            "ReturnData": True,
        },
        {
            "Id": "p50",
            "MetricStat": {
                "Metric": {
                    "Namespace": SITEUP_METRIC_NAMESPACE,
                    "MetricName": "LatencyMs",
                },
                "Period": period,
                "Stat": "p50",
            },
            "ReturnData": True,
        },
        {
            "Id": "p90",
            "MetricStat": {
                "Metric": {
                    "Namespace": SITEUP_METRIC_NAMESPACE,
                    "MetricName": "LatencyMs",
                },
                "Period": period,
                "Stat": "p90",
            },
            "ReturnData": True,
        },
    ]
    r = cloudwatch.get_metric_data(
        MetricDataQueries=queries,
        StartTime=start,
        EndTime=end,
        ScanBy="TimestampAscending",
    )
    results = {res["Id"]: res for res in r["MetricDataResults"]}
    avg_by_ts = dict(zip(results["avg"]["Timestamps"], results["avg"]["Values"]))
    cnt_by_ts = dict(zip(results["cnt"]["Timestamps"], results["cnt"]["Values"]))
    p50_by_ts = dict(zip(results["p50"]["Timestamps"], results["p50"]["Values"]))
    p90_by_ts = dict(zip(results["p90"]["Timestamps"], results["p90"]["Values"]))

    timestamps = set(avg_by_ts) | set(cnt_by_ts)

    return [
        (
            ts,
            avg_by_ts.get(ts),
            int(cnt_by_ts.get(ts, 0)),
            p50_by_ts.get(ts),
            p90_by_ts.get(ts),
        )
        for ts in sorted(timestamps)
    ]


# --- incidents ------------------------------------------------------------------


def log_records(group, now, days, stream=None):
    """[(log timestamp ms, parsed JSON message), ...] from `group` (one named
    stream, or all of them), unparseable lines skipped. The window is the log
    event timestamp, which is only a coarse bound: a backfilled record keeps
    its own old time but is logged at write time, so callers that care about a
    record's time read the record's own field.
    """
    kwargs = {
        "logGroupName": group,
        "startTime": int((now - datetime.timedelta(days=days)).timestamp() * 1000),
        "endTime": int(now.timestamp() * 1000),
    }
    if stream:
        kwargs["logStreamNames"] = [stream]
    records = []
    while True:
        r = logs.filter_log_events(**kwargs)
        for e in r.get("events", []):
            try:
                record = json.loads(e["message"])
            except ValueError:
                continue
            if isinstance(record, dict):
                records.append((e.get("timestamp", 0), record))
        token = r.get("nextToken")
        if not token:
            return records
        kwargs["nextToken"] = token


def latest_per(records, key):
    """The record with the latest log timestamp for each distinct `key(record)`.
    A retried event delivery repeats a record, and a backfill appends a revised
    one; either way the newest line stands in for the others. A record whose
    key is None has nothing to dedupe on and is kept as is.
    """
    newest, keyless = {}, []
    for _, rec in sorted(records, key=lambda pair: pair[0]):
        k = key(rec)
        if k is None:
            keyless.append(rec)
        else:
            newest[k] = rec
    return list(newest.values()) + keyless


def incidents(days=INCIDENTS_LOOKBACK_DAYS, now=None):
    now = now or datetime.datetime.now(datetime.UTC)
    # The producer (monitoring/lambda.tf's aws_cloudwatch_log_stream.episodes)
    # writes every episode to this one named stream; narrowing to it turns
    # this from a whole-log-group scan into a single-stream lookup. See
    # main.tf's episodes_log_stream local for the shared literal.
    records = log_records(EPISODES_LOG_GROUP, now, days, EPISODES_LOG_STREAM)
    episodes = latest_per(records, lambda ep: ep.get("started"))
    for ep in episodes:
        ep.setdefault("planned", False)  # pre-`planned` records were unplanned
    episodes.sort(key=lambda ep: ep.get("started", ""), reverse=True)
    return episodes


def changes(days=INCIDENTS_LOOKBACK_DAYS, now=None):
    """Deployments and instance refreshes recorded by the availability Lambda,
    newest first, one per id, each with `outage`: whether an episode of the
    change's own cause overlaps it (see change_caused_outage()). Windowed on
    the record's own `at`; lines lacking `id` or `at` are skipped.
    """
    now = now or datetime.datetime.now(datetime.UTC)
    cutoff = iso(now - datetime.timedelta(days=days))
    records = log_records(EPISODES_LOG_GROUP, now, days, CHANGES_LOG_STREAM)
    complete = [(ts, c) for ts, c in records if c.get("id") and c.get("at")]
    recorded = [c for c in latest_per(complete, lambda c: c["id"]) if c["at"] >= cutoff]
    episodes = incidents(days, now)
    for c in recorded:
        c["outage"] = change_caused_outage(c, episodes)
    recorded.sort(key=lambda c: c["at"], reverse=True)
    return recorded


def change_caused_outage(change, episodes):
    """True when an episode overlaps the change's [start, at] span within
    CHANGE_OUTAGE_SLACK_S and its cause is the change's own kind: a deploy by a
    deliberate creator and a `deploy` episode, an instance refresh and an
    `instance-refresh` episode. Downtime beside an unrelated episode, or beside
    an Auto Scaling launch deployment, belongs to that episode instead.
    """
    if change.get("kind") == "deploy" and not is_deliberate_deploy(change):
        return False
    slack = datetime.timedelta(seconds=CHANGE_OUTAGE_SLACK_S)
    end = parse_iso(change["at"])
    start = end - datetime.timedelta(seconds=change.get("duration_s") or 0)
    return any(
        ep.get("cause") == change.get("kind")
        and parse_iso(ep["started"]) <= end + slack
        and parse_iso(ep["ended"]) >= start - slack
        for ep in episodes
        if ep.get("started") and ep.get("ended")
    )


def is_deliberate_deploy(change):
    return change.get("creator") in DELIBERATE_DEPLOYMENT_CREATORS


def is_deliberate_change(change):
    return change.get("kind") != "deploy" or is_deliberate_deploy(change)


def interruptions(days=INCIDENTS_LOOKBACK_DAYS, now=None):
    """Spot interruption warnings, newest first, from the EventBridge log."""
    now = now or datetime.datetime.now(datetime.UTC)
    warnings = [
        {
            "time": event["time"],
            "instance_id": event["detail"]["instance-id"],
            "action": event["detail"].get("instance-action"),
        }
        for _, event in log_records(SPOT_INTERRUPTIONS_LOG_GROUP, now, days)
        if event.get("time")
        and isinstance(event.get("detail"), dict)
        and event["detail"].get("instance-id")
    ]
    warnings.sort(key=lambda w: w["time"], reverse=True)
    return warnings


# --- host -----------------------------------------------------------------------


def host():
    r = autoscaling.describe_auto_scaling_groups(AutoScalingGroupNames=[ASG_NAME])
    groups = r["AutoScalingGroups"]
    if not groups:
        return {"error": f"ASG {ASG_NAME} not found"}
    g = groups[0]
    capacity = {
        "desired": g["DesiredCapacity"],
        "min": g["MinSize"],
        "max": g["MaxSize"],
    }

    instances = g["Instances"]
    if not instances:
        return {"capacity": capacity, "instance": None}

    instance_id = instances[0]["InstanceId"]
    inst = ec2.describe_instances(InstanceIds=[instance_id])["Reservations"][0][
        "Instances"
    ][0]
    launch_time = inst["LaunchTime"]
    now = datetime.datetime.now(datetime.UTC)

    # The root EBS volume id, resolved from RootDeviceName against this same
    # describe_instances response -- a host-payload field storage() consumes
    # (host_image_storage()) the same way image() consumes ami_id, at zero
    # extra AWS calls.
    root_volume_id = None
    for bdm in inst.get("BlockDeviceMappings", []):
        if bdm.get("DeviceName") == inst.get("RootDeviceName"):
            root_volume_id = bdm.get("Ebs", {}).get("VolumeId")
            break

    return {
        "capacity": capacity,
        "instance": {
            "id": instance_id,
            "type": inst["InstanceType"],
            "architecture": inst["Architecture"],
            "az": inst["Placement"]["AvailabilityZone"],
            # Absent means on-demand.
            "lifecycle": inst.get("InstanceLifecycle", "on-demand"),
            "launch_time": iso(launch_time),
            "uptime_s": int((now - launch_time).total_seconds()),
            "ami_id": inst["ImageId"],
            "root_volume_id": root_volume_id,
        },
    }


# --- image ------------------------------------------------------------------------


def image(ami_id):
    if not ami_id:
        return {"error": "no running instance to read an AMI from"}
    images = ec2.describe_images(ImageIds=[ami_id])["Images"]
    if not images:
        return {"error": f"AMI {ami_id} not found"}
    img = images[0]
    tags = {t["Key"]: t["Value"] for t in img.get("Tags", [])}
    source_ami = tags.get("source_ami")

    # Best-effort second lookup: source_ami_name (the tag) is captured once,
    # at build time, and never goes stale; the AMI it names is a live AWS
    # resource that Amazon deregisters on its own cadence (base AL2023 AMIs
    # roll off after a few months). By the time anyone loads this page, the
    # source AMI this one was built from may already be gone --
    # InvalidAMIID.NotFound is the expected failure mode, not an edge case --
    # so this degrades to the tag instead of failing the whole Image block
    # over a provenance lookup nobody asked to be load-bearing.
    source_ami_description = None
    if source_ami:
        try:
            source_images = ec2.describe_images(ImageIds=[source_ami])["Images"]
            if source_images:
                source_ami_description = source_images[0].get("Description")
        except Exception as e:
            print(json.dumps({"source_ami_lookup_failed": f"{type(e).__name__}: {e}"}))

    return {
        "id": ami_id,
        "name": img.get("Name"),
        "creation_date": img.get("CreationDate"),
        "git_sha": tags.get("git_sha"),
        "source_ami": source_ami,
        "source_ami_name": tags.get("source_ami_name"),
        "source_ami_description": source_ami_description,
    }


def host_image_storage():
    """host(), image(), and storage() as one thread-pool branch, run
    sequentially: image() needs host()'s ami_id and storage() needs host()'s
    root_volume_id. Each third still isolates its own failure through
    safe_section, so a host error doesn't blank the other two -- image()
    degrades to its own "no running instance" message, storage() degrades to
    the data volume alone (root_volume_id is None).
    """
    host_info = safe_section("host", host)
    ami_id = None
    root_volume_id = None
    if isinstance(host_info, dict) and host_info.get("instance"):
        ami_id = host_info["instance"].get("ami_id")
        root_volume_id = host_info["instance"].get("root_volume_id")
    return {
        "host": host_info,
        "image": safe_section("image", image, ami_id),
        "storage": safe_section("storage", storage, root_volume_id),
    }


# --- deployment -------------------------------------------------------------------


def deployment():
    ids = codedeploy.list_deployments(
        applicationName=CODEDEPLOY_APP_NAME,
        deploymentGroupName=CODEDEPLOY_DEPLOYMENT_GROUP,
    ).get("deployments", [])
    if not ids:
        return {"error": "no deployments found"}

    details = codedeploy.batch_get_deployments(deploymentIds=ids[:25])[
        "deploymentsInfo"
    ]
    details.sort(
        key=lambda d: (
            d.get("createTime") or datetime.datetime.min.replace(tzinfo=datetime.UTC)
        ),
        reverse=True,
    )
    latest = details[0]
    succeeded = next((d for d in details if d.get("status") == "Succeeded"), None)

    commits = deployment_commits(details, pipeline_commits())
    result = {
        "latest": summarize_deployment(latest, commits),
        "latest_succeeded": summarize_deployment(succeeded, commits),
    }

    try:
        images = ecr.describe_images(repositoryName=ECR_REPO_NAME)["imageDetails"]
        images.sort(
            key=lambda i: (
                i.get("imagePushedAt")
                or datetime.datetime.min.replace(tzinfo=datetime.UTC)
            ),
            reverse=True,
        )
        if images:
            latest_image = images[0]
            result["ecr_latest_image"] = {
                "tags": latest_image.get("imageTags", []),
                "digest": latest_image.get("imageDigest"),
                "pushed_at": iso(latest_image["imagePushedAt"])
                if latest_image.get("imagePushedAt")
                else None,
            }
    except Exception as e:  # ECR read is a bonus on top of the deployment info
        result["ecr_error"] = f"{type(e).__name__}: {e}"

    return result


def pipeline_commits():
    """{deployment_id: commit_sha}, one entry per pipeline run whose Source and
    Deploy actions both succeeded. CodeDeploy revisions on this pipeline are
    S3-sourced (staged by the Build stage), so batch_get_deployments()'s own
    revision.gitHubLocation is always null -- this is the join back to the
    commit that actually triggered a *pipeline* deployment (see
    deployment_commits() for the Auto Scaling case). One page
    (maxResults=100, ordered latest-execution-first) covers far more
    pipeline runs than deployment()'s own ids[:25] ever looks at, so no
    pagination is needed. Degrades to {} on any failure -- a hiccup here
    should blank the Commit cell, not the whole deployment panel.
    """
    try:
        details = codepipeline.list_action_executions(
            pipelineName=CODEPIPELINE_NAME, maxResults=100
        )["actionExecutionDetails"]
    except Exception as e:
        print(json.dumps({"pipeline_commits_failed": f"{type(e).__name__}: {e}"}))
        return {}

    by_execution = {}
    for a in details:
        by_execution.setdefault(a["pipelineExecutionId"], {})[a["stageName"]] = a

    commits = {}
    for actions in by_execution.values():
        deploy = actions.get("Deploy")
        source = actions.get("Source")
        if not deploy or not source:
            continue
        deployment_id = (
            deploy.get("output", {})
            .get("executionResult", {})
            .get("externalExecutionId")
        )
        sha = (
            source.get("output", {})
            .get("executionResult", {})
            .get("externalExecutionId")
        )
        if deployment_id and sha:
            commits[deployment_id] = sha
    return commits


def revision_key(d):
    """(bucket, key, version) of a deployment's S3 revision, or None if any
    part is missing. Two deployments sharing a key deployed identical bytes
    -- an Auto Scaling launch replays an existing revision verbatim, so this
    is the exact fallback deployment_commits() needs, not a heuristic.
    """
    loc = (d.get("revision") or {}).get("s3Location") or {}
    bucket, key, version = loc.get("bucket"), loc.get("key"), loc.get("version")
    return (bucket, key, version) if bucket and key and version else None


def deployment_commits(details, pipeline):
    """{deployment_id: commit_sha} for every deployment in details, extending
    pipeline (deploymentId -> sha, from pipeline_commits()) to deployments
    the pipeline never triggered directly -- an Auto Scaling instance
    refresh redeploys the same revision, not a new one, so it inherits the
    commit of any deployment carrying the same revision_key().
    """
    by_revision = {}
    for d in details:
        key = revision_key(d)
        sha = pipeline.get(d.get("deploymentId"))
        if key and sha:
            by_revision.setdefault(key, sha)

    commits = dict(pipeline)
    for d in details:
        deployment_id = d.get("deploymentId")
        if deployment_id in commits:
            continue
        key = revision_key(d)
        if key and key in by_revision:
            commits[deployment_id] = by_revision[key]
    return commits


def summarize_deployment(d, commits):
    if not d:
        return None
    return {
        "id": d.get("deploymentId"),
        "status": d.get("status"),
        "create_time": iso(d["createTime"]) if d.get("createTime") else None,
        "commit": commits.get(d.get("deploymentId")),
    }


# --- storage ------------------------------------------------------------------------


def storage(root_volume_id):
    """root_volume_id comes from host()'s own describe_instances response
    (host_image_storage() passes it through), so this needs no separate EC2
    call to find it. A missing root id -- no running instance, or host()
    itself errored -- degrades to the data volume alone, same as a root id
    that describe_volumes doesn't return (e.g. mid-swap).
    """
    result = {}
    try:
        volume_ids = ([EBS_VOLUME_ID] if EBS_VOLUME_ID else []) + (
            [root_volume_id] if root_volume_id else []
        )
        volumes_by_id = (
            {
                v["VolumeId"]: v
                for v in ec2.describe_volumes(VolumeIds=volume_ids)["Volumes"]
            }
            if volume_ids
            else {}
        )
        volumes = []
        for role, volume_id in (("data", EBS_VOLUME_ID), ("root", root_volume_id)):
            if not volume_id:
                continue
            v = volumes_by_id.get(volume_id)
            if not v:
                continue
            attachments = v.get("Attachments") or []
            volumes.append(
                {
                    "role": role,
                    "id": volume_id,
                    "device": attachments[0].get("Device") if attachments else None,
                    "size_gb": v.get("Size"),
                    "type": v.get("VolumeType"),
                    "iops": v.get("Iops"),
                    "encrypted": v.get("Encrypted"),
                    "state": v.get("State"),
                }
            )
        result["volumes"] = volumes
    except Exception as e:
        result["volume_error"] = f"{type(e).__name__}: {e}"

    # Published once/day; look back 2 days so a just-missed publish still has
    # a datapoint to show.
    now = datetime.datetime.now(datetime.UTC)
    start = now - datetime.timedelta(days=2)
    size, count = s3_bucket_metrics(start, now)
    result["bucket_size_bytes"] = size
    result["bucket_object_count"] = int(count) if count is not None else None
    return result


def s3_bucket_metrics(start, end):
    """(size_bytes, object_count), both from one GetMetricData call -- the two
    values are separate CloudWatch metrics, but querying them together halves
    the calls this panel makes.

    `size` is a metric-math expression, not a plain MetricStat: S3 publishes
    BucketSizeBytes per StorageType (StandardStorage, IntelligentTieringFAStorage,
    GlacierStorage, ...) and no AllStorageTypes rollup for size the way it does
    for NumberOfObjects. This bucket's lifecycle rule transitions every object
    to Intelligent-Tiering at day 0, so a hardcoded StorageType=StandardStorage
    dimension (the previous query) reads only the sliver of data still sitting
    in the class objects transition out of immediately -- 14.7 MB of an actual
    124.1 MiB, an 89% undercount, not a rounding difference. SEARCH() finds
    every StorageType series that exists for this bucket at query time and
    SUM() adds them, so the total is correct today and self-corrects if the
    lifecycle configuration (or S3's set of storage classes) changes later,
    which a hardcoded dimension cannot. Evaluated inside GetMetricData itself,
    so this costs no separate cloudwatch:ListMetrics call or IAM grant.
    """
    size_search = (
        'SUM(SEARCH(\'{AWS/S3,BucketName,StorageType} MetricName="BucketSizeBytes" '
        f"BucketName=\"{MEDIA_BUCKET_NAME}\"', 'Average', 86400))"
    )
    try:
        r = cloudwatch.get_metric_data(
            MetricDataQueries=[
                {
                    "Id": "size",
                    "Expression": size_search,
                    "Period": 86400,
                    "ReturnData": True,
                },
                {
                    "Id": "count",
                    "MetricStat": {
                        "Metric": {
                            "Namespace": "AWS/S3",
                            "MetricName": "NumberOfObjects",
                            "Dimensions": [
                                {"Name": "BucketName", "Value": MEDIA_BUCKET_NAME},
                                {"Name": "StorageType", "Value": "AllStorageTypes"},
                            ],
                        },
                        "Period": 86400,
                        "Stat": "Average",
                    },
                    "ReturnData": True,
                },
            ],
            StartTime=start,
            EndTime=end,
            ScanBy="TimestampDescending",
        )
        results = {res["Id"]: res for res in r["MetricDataResults"]}
        size_values = results["size"]["Values"]
        count_values = results["count"]["Values"]
        return (
            size_values[0] if size_values else None,
            count_values[0] if count_values else None,
        )
    except Exception as e:
        print(json.dumps({"s3_metrics_failed": f"{type(e).__name__}: {e}"}))
        return None, None


# --- backups --------------------------------------------------------------------------


def backups():
    now = datetime.datetime.now(datetime.UTC)
    result = {
        "mode": BACKUP_MODE,
        "schedule": BACKUP_SCHEDULE,
        "retention_days": int(BACKUP_RETENTION_DAYS) if BACKUP_RETENTION_DAYS else None,
        "resource_count": int(BACKUP_RESOURCE_COUNT) if BACKUP_RESOURCE_COUNT else None,
        "remote_retention_days": int(BACKUP_REMOTE_RETENTION_DAYS)
        if BACKUP_REMOTE_RETENTION_DAYS
        else None,
    }

    try:
        vault = backup_client.describe_backup_vault(BackupVaultName=BACKUP_VAULT_NAME)
        result["local"] = {
            "name": vault.get("BackupVaultName"),
            "region": backup_client.meta.region_name,
            "recovery_points": vault.get("NumberOfRecoveryPoints"),
            "locked": vault.get("Locked", False),
        }
    except Exception as e:
        result["vault_error"] = f"{type(e).__name__}: {e}"

    week_ago = now - datetime.timedelta(days=7)

    # Four job-listing calls, two of them account-wide ListCopyJobs scans (the
    # module docstring's previous long pole) narrowed client-side to copies
    # sourced from our vault. Run concurrently instead of serially; each keeps
    # its own error handling below, so one failing still degrades only its own
    # piece of the panel. describe_destination_vault (item 4) rides along as a
    # fifth task at no extra wall time when a destination is configured.
    tasks = {
        "completed_backup": lambda: backup_client.list_backup_jobs(
            ByBackupVaultName=BACKUP_VAULT_NAME, ByState="COMPLETED"
        ).get("BackupJobs", []),
        "completed_copy": lambda: [
            j
            for j in backup_client.list_copy_jobs(
                ByState="COMPLETED", ByCreatedAfter=now - datetime.timedelta(days=35)
            ).get("CopyJobs", [])
            if (j.get("SourceBackupVaultArn") or "").endswith(
                f":backup-vault:{BACKUP_VAULT_NAME}"
            )
        ],
        "failed_backup": lambda: backup_client.list_backup_jobs(
            ByBackupVaultName=BACKUP_VAULT_NAME,
            ByState="FAILED",
            ByCreatedAfter=week_ago,
        ).get("BackupJobs", []),
        "failed_copy": lambda: [
            j
            for j in backup_client.list_copy_jobs(
                ByState="FAILED", ByCreatedAfter=week_ago
            ).get("CopyJobs", [])
            if (j.get("SourceBackupVaultArn") or "").endswith(
                f":backup-vault:{BACKUP_VAULT_NAME}"
            )
        ],
    }
    if BACKUP_COPY_VAULT_ARN:
        tasks["destination"] = describe_destination_vault

    with concurrent.futures.ThreadPoolExecutor(max_workers=len(tasks)) as pool:
        futures = {name: pool.submit(fn) for name, fn in tasks.items()}

    def result_of(name):
        try:
            return futures[name].result(), None
        except Exception as e:
            return None, f"{type(e).__name__}: {e}"

    completed_backup, err = result_of("completed_backup")
    if err:
        result["backup_jobs_error"] = err
    elif completed_backup:
        completed_backup.sort(
            key=lambda j: (
                j.get("CompletionDate")
                or datetime.datetime.min.replace(tzinfo=datetime.UTC)
            ),
            reverse=True,
        )
        result["latest_backup"] = completion_summary(
            completed_backup[0].get("CompletionDate")
        )

    completed_copy, err = result_of("completed_copy")
    if err:
        result["copy_jobs_error"] = err
    elif completed_copy:
        completed_copy.sort(
            key=lambda j: (
                j.get("CompletionDate")
                or datetime.datetime.min.replace(tzinfo=datetime.UTC)
            ),
            reverse=True,
        )
        result["latest_copy"] = completion_summary(
            completed_copy[0].get("CompletionDate")
        )

    # A count, not a list: enough to flag a silently-stopped backup without
    # growing the response with job detail nobody reads from this panel.
    failed_backup, backup_err = result_of("failed_backup")
    failed_copy, copy_err = result_of("failed_copy")
    if backup_err or copy_err:
        result["failed_jobs_error"] = backup_err or copy_err
    else:
        result["failed_jobs_7d"] = len(failed_backup) + len(failed_copy)

    if BACKUP_COPY_VAULT_ARN:
        # Name and account come from the ARN the storage module already
        # computed; region comes from BACKUP_REGION directly, since Terraform
        # already carries it as config rather than it needing to be
        # re-parsed out of the same string.
        result["destination"] = {
            "name": BACKUP_COPY_VAULT_ARN.rsplit(":", 1)[-1],
            "region": BACKUP_REGION,
            "account_id": BACKUP_COPY_VAULT_ARN.split(":")[4],
        }
        dest_vault, dest_err = result_of("destination")
        if dest_err:
            # The panel must not assert a lock state it could not read.
            result["destination_error"] = dest_err
        else:
            result["destination"]["locked"] = dest_vault.get("Locked", False)
            result["destination"]["recovery_points"] = dest_vault.get(
                "NumberOfRecoveryPoints"
            )

    return result


def describe_destination_vault():
    """DescribeBackupVault on the off-site destination vault (item 4).

    Two paths, chosen by whether BACKUP_DEST_READER_ROLE_ARN is set:
    cross_region's destination is this same account in another region, read
    directly (see the DescribeBackupVault statement in iam.tf); cross_account's
    is a different account entirely, which AWS rejects direct reads against
    regardless of IAM grants (the replica vault's policy grants exactly
    backup:CopyIntoBackupVault), so that path assumes the backup account's
    gramps-web-vault-reader role instead. Terraform sets the role ARN only
    when the destination account differs (see backup_dest_reader_role_arn in
    locals.tf), so its presence is equivalent to comparing the two
    accounts here.
    """
    vault_name = BACKUP_COPY_VAULT_ARN.rsplit(":", 1)[-1]
    if BACKUP_DEST_READER_ROLE_ARN:
        creds = boto3.client("sts", config=BOTO_CONFIG).assume_role(
            RoleArn=BACKUP_DEST_READER_ROLE_ARN, RoleSessionName="gramps-web-status"
        )["Credentials"]
        client = boto3.client(
            "backup",
            region_name=BACKUP_REGION,
            aws_access_key_id=creds["AccessKeyId"],
            aws_secret_access_key=creds["SecretAccessKey"],
            aws_session_token=creds["SessionToken"],
            config=BOTO_CONFIG,
        )
    else:
        client = boto3.client("backup", region_name=BACKUP_REGION, config=BOTO_CONFIG)
    return client.describe_backup_vault(BackupVaultName=vault_name)


def completion_summary(completed_at):
    if not completed_at:
        return None
    now = datetime.datetime.now(datetime.UTC)
    return {
        "completed": iso(completed_at),
        "age_s": int((now - completed_at).total_seconds()),
    }


# --- assistant --------------------------------------------------------------------------


def assistant(now=None, keys=None):
    """Per-CHART_RANGES Bedrock token series (oldest to newest, today/this-
    period inclusive), plus the configured model/region and the three static
    config values (max requests, max tokens per run, max context length)
    surfaced as-is from Terraform.

    now/keys: /_status/series' panning hooks, same contract as
    reliability()'s (see its docstring) -- now=None/keys=None reproduce
    /_status/data's live, all-five-ranges call exactly.

    The model is reported from config (LLM_MODEL_ID), not discovered: a
    per-model breakdown would need SEARCH('{AWS/Bedrock,ModelId} ...'), but
    CloudWatch's metric index only surfaces metrics active in the last ~2
    weeks, so that search returns nothing over a 30-day-or-longer window
    whenever traffic is sparse -- while GetMetricData on the zero-dimension
    series below still answers. The configured model is authoritative and
    free, where discovery here would be neither.

    Totals (input/output/overall) are not shipped per range -- the frontend
    sums the two arrays for whichever range is selected, since that's
    strictly cheaper than the server precomputing a total for every range
    up front.

    24h/7d query this Sum counter at Period=1800/3600 rather than daily --
    fine, and expected to make already-sparse traffic look spikier at that
    resolution than the 30d+ daily view does; not a bug.
    """
    now = now or datetime.datetime.now(datetime.UTC)
    keys = keys or list(CHART_RANGES)

    # Queries are deduplicated by period_s: 30d/90d/1y all name
    # period_s=86400 in CHART_RANGES and so share one GetMetricData call,
    # sized to the longest of the three (1y, 365 cells), rather than issuing
    # three identical ones -- see reliability()'s query_cache for the same
    # idiom.
    query_cache = {}

    def query(period_s):
        if period_s not in query_cache:
            max_cells = max(
                spec["cells"]
                for spec in CHART_RANGES.values()
                if spec["period_s"] == period_s
            )
            period_td = datetime.timedelta(seconds=period_s)
            strip_start = floor_utc(now, period_s) - (max_cells - 1) * period_td
            r = llm_cloudwatch.get_metric_data(
                MetricDataQueries=[
                    {
                        "Id": "input",
                        "MetricStat": {
                            "Metric": {
                                "Namespace": "AWS/Bedrock",
                                "MetricName": "InputTokenCount",
                            },
                            "Period": period_s,
                            "Stat": "Sum",
                        },
                        "ReturnData": True,
                    },
                    {
                        "Id": "output",
                        "MetricStat": {
                            "Metric": {
                                "Namespace": "AWS/Bedrock",
                                "MetricName": "OutputTokenCount",
                            },
                            "Period": period_s,
                            "Stat": "Sum",
                        },
                        "ReturnData": True,
                    },
                ],
                StartTime=strip_start - period_td,
                EndTime=now,
                ScanBy="TimestampAscending",
            )
            query_cache[period_s] = {res["Id"]: res for res in r["MetricDataResults"]}
        return query_cache[period_s]

    token_ranges = {}
    for range_key in keys:
        spec = CHART_RANGES[range_key]
        period_s = spec["period_s"]
        period_td = datetime.timedelta(seconds=period_s)
        strip_start = floor_utc(now, period_s) - (spec["cells"] - 1) * period_td
        results = query(period_s)
        # Zero-fill, not gap: these are Sum-stat counters, and a bucket
        # bucket_series() left None means CloudWatch returned no
        # InputTokenCount/OutputTokenCount datapoint for that period, i.e.
        # zero invocations -- unlike host_metrics()/latency_cells()'s
        # gauges, where a missing datapoint means unmeasured and must stay
        # a gap. Filling here also lets the chart draw a continuous line
        # instead of isolated single-point segments.
        token_ranges[range_key] = {
            "input": [
                int(v) if v is not None else 0
                for v in bucket_series(
                    results["input"]["Timestamps"],
                    results["input"]["Values"],
                    strip_start,
                    period_td,
                    spec["cells"],
                )
            ],
            "output": [
                int(v) if v is not None else 0
                for v in bucket_series(
                    results["output"]["Timestamps"],
                    results["output"]["Values"],
                    strip_start,
                    period_td,
                    spec["cells"],
                )
            ],
        }

    return {
        "model_id": LLM_MODEL_ID,
        "region": LLM_REGION,
        "max_requests": int(LLM_MAX_REQUESTS) if LLM_MAX_REQUESTS else None,
        "max_tokens": int(LLM_MAX_TOKENS) if LLM_MAX_TOKENS else None,
        "max_context_length": int(LLM_MAX_CONTEXT_LENGTH)
        if LLM_MAX_CONTEXT_LENGTH
        else None,
        "token_ranges": token_ranges,
    }


# --- cost -------------------------------------------------------------------------------


def cost():
    now_ts = time.time()
    if (
        _cost_cache["data"] is not None
        and (now_ts - _cost_cache["fetched_at"]) < COST_CACHE_TTL_S
    ):
        return _cost_cache["data"]

    today = datetime.datetime.now(datetime.UTC).date()
    start = today.replace(day=1)
    # GetCostAndUsage's End is exclusive; today itself is fine to exclude
    # since it is (by definition) not yet billed in full.
    r = ce.get_cost_and_usage(
        TimePeriod={"Start": start.isoformat(), "End": today.isoformat()},
        Granularity="MONTHLY",
        Metrics=["UnblendedCost"],
        GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
    )
    groups = (r.get("ResultsByTime") or [{}])[0].get("Groups", [])
    breakdown = [
        {
            "service": g["Keys"][0],
            "amount_usd": round(float(g["Metrics"]["UnblendedCost"]["Amount"]), 2),
        }
        for g in groups
    ]
    breakdown.sort(key=lambda b: b["amount_usd"], reverse=True)

    result = {
        "month_to_date_usd": round(sum(b["amount_usd"] for b in breakdown), 2),
        "top_services": breakdown[:10],
        "budget_usd": float(MONTHLY_BUDGET_USD) if MONTHLY_BUDGET_USD else None,
    }
    _cost_cache["data"] = result
    _cost_cache["fetched_at"] = now_ts
    return result


# --- host_metrics -------------------------------------------------------------------------


# (response key, namespace, CloudWatch metric name, dimensions). cpu_percent
# reads AWS/EC2 CPUUtilization dimensioned by AutoScalingGroupName rather
# than InstanceId: it is published natively by EC2 for every instance
# regardless of what's installed on it, so it needs no instance-side
# publisher at all, and -- because it's ASG-dimensioned, not
# instance-dimensioned -- the series survives a spot reclaim or a rightsize
# replacement instead of resetting to "no data" every time the ASG swaps in
# a new instance (see the module docstring's note on instance churn). The
# rest have no AWS-native equivalent -- memory and disk usage are inside the
# guest OS, invisible to the hypervisor -- so they exist only because
# health-watchdog.timer's publish_host_metrics() (build/ami/
# health-watchdog.sh) shells out to `aws cloudwatch put-metric-data` on its
# own ~5-minute cadence, not a CloudWatch Agent (this AMI runs neither the
# agent nor an OTel collector); any of them goes quiet (not error, just gap)
# if the timer stops or the instance is mid-swap.
#
# The disk entries mirror the publisher's own mutually exclusive arms
# exactly: VOLUME_METRICS_ENABLED picks either the four byte series (each
# Mount-dimensioned, superseding the percent) or the single legacy percent
# -- never both, since the publisher only ever emits one of the two.
HOST_METRIC_SPECS = (
    (
        "cpu_percent",
        "AWS/EC2",
        "CPUUtilization",
        [{"Name": "AutoScalingGroupName", "Value": ASG_NAME}],
    ),
    ("mem_used_percent", SITEUP_METRIC_NAMESPACE, "MemUsedPercent", []),
) + (
    (
        (
            "disk_used_bytes_data",
            SITEUP_METRIC_NAMESPACE,
            "DiskUsedBytes",
            [{"Name": "Mount", "Value": "data"}],
        ),
        (
            "disk_total_bytes_data",
            SITEUP_METRIC_NAMESPACE,
            "DiskTotalBytes",
            [{"Name": "Mount", "Value": "data"}],
        ),
        (
            "disk_used_bytes_root",
            SITEUP_METRIC_NAMESPACE,
            "DiskUsedBytes",
            [{"Name": "Mount", "Value": "root"}],
        ),
        (
            "disk_total_bytes_root",
            SITEUP_METRIC_NAMESPACE,
            "DiskTotalBytes",
            [{"Name": "Mount", "Value": "root"}],
        ),
    )
    if VOLUME_METRICS_ENABLED == "true"
    else (("disk_used_percent", SITEUP_METRIC_NAMESPACE, "DiskUsedPercent", []),)
)


def host_metrics(now=None, keys=None):
    """Per-CHART_RANGES series for every HOST_METRIC_SPECS entry (CPU,
    memory, and disk -- either an integer percent or four byte series
    depending on VOLUME_METRICS_ENABLED). Queries are deduplicated by
    period_s -- 30d/90d/1y all name period_s=86400 in CHART_RANGES and so
    share one GetMetricData call, sized to the longest of the three (1y, 365
    cells), rather than issuing three identical ones (see reliability()'s
    query_cache for the same idiom) -- for 3 calls total
    instead of 5.

    Each metric comes back as {"current": <newest value or None>, "ranges":
    {"24h": [...], "7d": [...], ...}} -- current is read off the 24h query's
    own newest CloudWatch datapoint (not off any bucketed array, which is
    calendar-aligned and can legitimately lag the true newest point by a few
    minutes), so a stat tile next to the chart never shows a value older
    than the 24h chart's own last visible point. It stays range-independent
    on purpose: Storage.tsx's disk meter/chart reads it and has no range
    selector of its own to key off (the percent-path meter; the byte-path
    chart has its own).

    Per-metric error isolation is kept: every metric fails independently
    from this function's point of view. The three underlying GetMetricData
    calls are issued eagerly, outside any per-metric try/except, so a call
    failure (network, throttling, IAM) propagates out of this function
    entirely and is caught by safe_section() the same way every other
    panel's total failure is -- not swallowed here into a per-metric
    "_error" that safe_section() would never see. Once all calls have
    succeeded, an unexpected shape in one MetricDataResults entry (a missing
    Id, an empty Values list where one wasn't expected) degrades only that
    metric to {"<key>_error": ...} rather than the whole panel.

    now/keys: /_status/series' panning hooks, same contract as
    reliability()'s (see its docstring), with one addition -- "current" is
    omitted (None) unless "24h" is itself among `keys`, since it always
    needs its own dedicated 1800s-period query (24h is the only CHART_RANGES
    entry at that period_s) and a panned single-range request has no caller
    for a "current" value: App.tsx's series wiring reads only the panned
    `ranges[key]` and leaves every panel's live `current`/tile untouched
    (see the parent plan's client section). keys=None (the /_status/data
    default) always includes "24h", so that response is unaffected.
    """
    now = now or datetime.datetime.now(datetime.UTC)
    keys = keys or list(CHART_RANGES)
    query_cache = {}

    def query(period_s):
        if period_s not in query_cache:
            max_cells = max(
                spec["cells"]
                for spec in CHART_RANGES.values()
                if spec["period_s"] == period_s
            )
            period_td = datetime.timedelta(seconds=period_s)
            strip_start = floor_utc(now, period_s) - (max_cells - 1) * period_td
            r = cloudwatch.get_metric_data(
                MetricDataQueries=[
                    {
                        "Id": key,
                        "MetricStat": {
                            "Metric": {
                                "Namespace": namespace,
                                "MetricName": metric_name,
                                "Dimensions": dims,
                            },
                            "Period": period_s,
                            "Stat": "Average",
                        },
                        "ReturnData": True,
                    }
                    for key, namespace, metric_name, dims in HOST_METRIC_SPECS
                ],
                StartTime=strip_start - period_td,
                EndTime=now,
                ScanBy="TimestampAscending",
            )
            # StartTime above is floored to period_s, so CloudWatch's own
            # flooring of StartTime to the nearest multiple of Period (same
            # behavior reliability()'s query() comment
            # documents) is a no-op here too -- this is the same class of
            # bug fixed in d95f93d (unaligned StartTime vs. an
            # exact-timestamp join), applied to this panel.
            query_cache[period_s] = {res["Id"]: res for res in r["MetricDataResults"]}
        return query_cache[period_s]

    for period_s in sorted({CHART_RANGES[k]["period_s"] for k in keys}):
        query(period_s)

    current_period_s = CHART_RANGES["24h"]["period_s"]
    result = {}
    for key, _namespace, _metric_name, _dims in HOST_METRIC_SPECS:
        try:
            ranges = {}
            for range_key in keys:
                spec = CHART_RANGES[range_key]
                period_s = spec["period_s"]
                period_td = datetime.timedelta(seconds=period_s)
                strip_start = floor_utc(now, period_s) - (spec["cells"] - 1) * period_td
                res = query(period_s)[key]
                ranges[range_key] = [
                    round(v, 1) if v is not None else None
                    for v in bucket_series(
                        res["Timestamps"],
                        res["Values"],
                        strip_start,
                        period_td,
                        spec["cells"],
                    )
                ]
            current = None
            if current_period_s in query_cache:
                current_res = query(current_period_s)[key]
                by_ts = dict(zip(current_res["Timestamps"], current_res["Values"]))
                newest_ts = (
                    max(current_res["Timestamps"])
                    if current_res["Timestamps"]
                    else None
                )
                current = round(by_ts[newest_ts], 1) if newest_ts is not None else None
            result[key] = {"current": current, "ranges": ranges}
        except Exception as e:
            result[f"{key}_error"] = f"{type(e).__name__}: {e}"
    return result


# --- helpers -------------------------------------------------------------------------------


def iso(dt):
    return dt.astimezone(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
