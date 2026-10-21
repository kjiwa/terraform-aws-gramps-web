"""Pure-function tests for the availability monitor's cause attribution and
edge-detection logic (classify_cause, attributed_by_marker, first_down,
recovery). No AWS dependency: boto3/botocore are stubbed out below before
availability.py is imported, so this never needs credentials, a region, or
network access -- only availability.py's module-level `boto3.client(...)`
calls need to not blow up at import time. The pulled-lookup collaborators
(recent_deployment, recent_instance_refresh, recent_scaling_cause), which
do make AWS calls, are monkeypatched rather than exercised, keeping
classify_cause's ordering the thing under test. End-to-end sequences live in
test_availability_replay.py.

Runnable two ways:
    pytest test_availability.py
    python3 test_availability.py
"""

import datetime
import importlib
import os
import sys
import types
import unittest
from unittest import mock

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

# --- stub boto3/botocore so importing availability.py makes zero AWS calls
# and needs no region/credentials -- mirrors modules/status/lambda/test_status.py. ---

if "boto3" not in sys.modules:
    _fake_boto3 = types.ModuleType("boto3")

    class _FakeClient:
        def __init__(self, *args, **kwargs):
            pass

    _fake_boto3.client = lambda *args, **kwargs: _FakeClient()
    sys.modules["boto3"] = _fake_boto3

if "botocore" not in sys.modules:
    _fake_botocore = types.ModuleType("botocore")
    _fake_botocore_config = types.ModuleType("botocore.config")

    class _FakeConfig:
        def __init__(self, *args, **kwargs):
            pass

    _fake_botocore_config.Config = _FakeConfig
    _fake_botocore.config = _fake_botocore_config
    sys.modules["botocore"] = _fake_botocore
    sys.modules["botocore.config"] = _fake_botocore_config

# availability.py reads these via os.environ[...] (no default) at module level.
for _var, _val in [
    ("SITE_URL", "https://example.invalid"),
    ("ASG_NAME", "test-asg"),
    ("SNS_TOPIC_ARN", "arn:aws:sns:us-east-1:000000000000:test-topic"),
    ("STATE_PARAM", "/test/state"),
    ("EPISODES_LOG_GROUP", "test-log-group"),
    ("EPISODES_LOG_STREAM", "test-log-stream"),
    ("CHANGES_LOG_STREAM", "test-changes-stream"),
    ("METRIC_NAMESPACE", "test/SiteUp"),
    ("CODEDEPLOY_APP_NAME", "test-app"),
    ("CODEDEPLOY_DEPLOYMENT_GROUP", "test-group"),
    ("LAST_RIGHTSIZE_PARAM", "/test/last-rightsize"),
    ("LAST_HEALTH_WATCHDOG_PARAM", "/test/last-health-watchdog"),
    ("LAST_BACKUP_SNAPSHOT_PARAM", "/test/last-backup-snapshot"),
    ("DELIBERATE_DEPLOYMENT_CREATORS", "user,codeDeployRollback"),
]:
    os.environ.setdefault(_var, _val)

import availability

UTC = datetime.UTC


def dt(*args):
    return datetime.datetime(*args, tzinfo=UTC)


def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


BEFORE = availability.MARKER_LEAD_BEFORE_OUTAGE_S
AFTER = availability.MARKER_LEAD_AFTER_APP_STOPPED_S


class AttributedByMarkerTests(unittest.TestCase):
    """Window-math edge cases for attributed_by_marker(marker, started,
    min_lead_s, max_lead_s), where lead = started - marker time."""

    started = dt(2026, 7, 15, 12, 15, 0)

    def marker_lead(self, lead_s):
        return {"time": iso(self.started - datetime.timedelta(seconds=lead_s))}

    def test_none_marker_is_false(self):
        self.assertFalse(availability.attributed_by_marker(None, self.started, *BEFORE))

    def test_empty_marker_is_false(self):
        self.assertFalse(availability.attributed_by_marker({}, self.started, *BEFORE))

    def test_marker_missing_time_key_is_false(self):
        self.assertFalse(
            availability.attributed_by_marker({"id": "i-123"}, self.started, *BEFORE)
        )

    def test_before_outage_window_edges(self):
        lo, hi = BEFORE
        for lead_s, expected in [
            (hi, True),
            (hi + 1, False),
            (0, True),
            (lo, True),
            (lo - 1, False),
        ]:
            with self.subTest(lead_s=lead_s):
                self.assertEqual(
                    availability.attributed_by_marker(
                        self.marker_lead(lead_s), self.started, *BEFORE
                    ),
                    expected,
                )

    def test_after_app_stopped_window_edges(self):
        lo, hi = AFTER
        for lead_s, expected in [
            (lo, True),
            (lo - 1, False),
            (0, True),
            (hi, True),
            (hi + 1, False),
        ]:
            with self.subTest(lead_s=lead_s):
                self.assertEqual(
                    availability.attributed_by_marker(
                        self.marker_lead(lead_s), self.started, *AFTER
                    ),
                    expected,
                )


class ClassifyCauseOrderingTests(unittest.TestCase):
    """classify_cause() tries checks in a fixed order and takes the first
    match. Each test arranges synthetic signals so more than one check WOULD
    match, to prove the earlier one in the order wins.
    """

    def setUp(self):
        self.started = dt(2026, 7, 15, 12, 30, 0)
        self.ended = dt(2026, 7, 15, 12, 40, 0)
        self.matching = set()
        self._patches = [
            mock.patch.object(
                availability,
                "recent_deployment",
                side_effect=lambda *_: "deploy" in self.matching,
            ),
            mock.patch.object(
                availability,
                "recent_instance_refresh",
                side_effect=lambda *_: "instance-refresh" in self.matching,
            ),
            mock.patch.object(
                availability,
                "recent_scaling_cause",
                side_effect=lambda _s, _e, fragment: fragment in self.matching,
            ),
        ]
        for p in self._patches:
            p.start()
            self.addCleanup(p.stop)

    def marker_at(self, seconds_before):
        return {"time": iso(self.started - datetime.timedelta(seconds=seconds_before))}

    def classify(self, interruption=None, markers=None):
        markers = markers or {}
        with mock.patch.object(
            availability, "load_marker", side_effect=lambda name: markers.get(name, {})
        ):
            return availability.classify_cause(self.started, self.ended, interruption)

    def test_spot_reclaim_beats_everything(self):
        self.matching = {
            "deploy",
            "instance-refresh",
            availability.DESIRED_CAPACITY_CAUSE,
            availability.UNHEALTHY_CAUSE,
        }
        markers = {
            availability.LAST_RIGHTSIZE_PARAM: self.marker_at(60),
            availability.LAST_HEALTH_WATCHDOG_PARAM: self.marker_at(60),
            availability.LAST_BACKUP_SNAPSHOT_PARAM: self.marker_at(60),
        }
        self.assertEqual(self.classify(self.marker_at(60), markers), "spot-reclaim")

    def test_rightsize_beats_health_watchdog_backup_and_pulled_checks(self):
        self.matching = {"deploy", "instance-refresh"}
        markers = {
            availability.LAST_RIGHTSIZE_PARAM: self.marker_at(-60),
            availability.LAST_HEALTH_WATCHDOG_PARAM: self.marker_at(-60),
            availability.LAST_BACKUP_SNAPSHOT_PARAM: self.marker_at(60),
        }
        self.assertEqual(self.classify(markers=markers), "rightsize")

    def test_health_watchdog_beats_backup(self):
        markers = {
            availability.LAST_HEALTH_WATCHDOG_PARAM: self.marker_at(-60),
            availability.LAST_BACKUP_SNAPSHOT_PARAM: self.marker_at(60),
        }
        self.assertEqual(self.classify(markers=markers), "health-watchdog")

    def test_backup_beats_pulled_checks(self):
        self.matching = {"deploy"}
        markers = {availability.LAST_BACKUP_SNAPSHOT_PARAM: self.marker_at(60)}
        self.assertEqual(self.classify(markers=markers), "backup")

    def test_deploy_beats_refresh_and_scaling(self):
        self.matching = {"deploy", "instance-refresh", availability.UNHEALTHY_CAUSE}
        self.assertEqual(self.classify(), "deploy")

    def test_instance_refresh_beats_scaling(self):
        self.matching = {"instance-refresh", availability.DESIRED_CAPACITY_CAUSE}
        self.assertEqual(self.classify(), "instance-refresh")

    def test_capacity_change_beats_health_replace(self):
        self.matching = {
            availability.DESIRED_CAPACITY_CAUSE,
            availability.UNHEALTHY_CAUSE,
        }
        self.assertEqual(self.classify(), "capacity-change")

    def test_health_replace_is_last_before_unknown(self):
        self.matching = {availability.UNHEALTHY_CAUSE}
        self.assertEqual(self.classify(), "health-replace")

    def test_unknown_when_nothing_matches(self):
        self.assertEqual(self.classify(), "unknown")

    def test_stale_spot_interruption_outside_window_falls_through(self):
        self.matching = {"deploy"}
        self.assertEqual(self.classify(self.marker_at(3600)), "deploy")

    def test_planned_causes(self):
        self.assertEqual(
            availability.PLANNED_CAUSES,
            {"rightsize", "deploy", "instance-refresh", "capacity-change", "backup"},
        )


class FirstDownRecoveryTests(unittest.TestCase):
    """Edge-detection over a synthetic SiteUp metric time series:
    [(timestamp, value), ...] where value < 1 means down.
    """

    def test_first_down_picks_earliest_failing_datapoint(self):
        series = [
            (dt(2026, 7, 15, 12, 0, 0), 1),
            (dt(2026, 7, 15, 12, 1, 0), 0),
            (dt(2026, 7, 15, 12, 2, 0), 0),
            (dt(2026, 7, 15, 12, 3, 0), 1),
        ]
        fallback = dt(2026, 7, 15, 11, 0, 0)
        self.assertEqual(
            availability.first_down(series, fallback), dt(2026, 7, 15, 12, 1, 0)
        )

    def test_first_down_falls_back_when_never_down(self):
        series = [
            (dt(2026, 7, 15, 12, 0, 0), 1),
            (dt(2026, 7, 15, 12, 1, 0), 1),
        ]
        fallback = dt(2026, 7, 15, 11, 0, 0)
        self.assertEqual(availability.first_down(series, fallback), fallback)

    def test_first_down_falls_back_on_empty_series(self):
        fallback = dt(2026, 7, 15, 11, 0, 0)
        self.assertEqual(availability.first_down([], fallback), fallback)

    def test_first_down_when_down_for_entire_window(self):
        series = [
            (dt(2026, 7, 15, 12, 0, 0), 0),
            (dt(2026, 7, 15, 12, 1, 0), 0),
            (dt(2026, 7, 15, 12, 2, 0), 0),
        ]
        fallback = dt(2026, 7, 15, 11, 0, 0)
        self.assertEqual(
            availability.first_down(series, fallback), dt(2026, 7, 15, 12, 0, 0)
        )

    def test_recovery_anchors_to_last_down_not_first(self):
        # A mid-outage flap (down, up, down, up) must not cut the outage short:
        # recovery should return the pass AFTER the LAST failing datapoint.
        series = [
            (dt(2026, 7, 15, 12, 0, 0), 0),
            (dt(2026, 7, 15, 12, 1, 0), 1),  # a flap back up
            (dt(2026, 7, 15, 12, 2, 0), 0),  # down again
            (dt(2026, 7, 15, 12, 3, 0), 1),  # the real recovery
        ]
        fallback = dt(2026, 7, 15, 13, 0, 0)
        self.assertEqual(
            availability.recovery(series, fallback), dt(2026, 7, 15, 12, 3, 0)
        )

    def test_recovery_falls_back_when_never_down(self):
        series = [
            (dt(2026, 7, 15, 12, 0, 0), 1),
            (dt(2026, 7, 15, 12, 1, 0), 1),
        ]
        fallback = dt(2026, 7, 15, 13, 0, 0)
        self.assertEqual(availability.recovery(series, fallback), fallback)

    def test_recovery_falls_back_on_empty_series(self):
        fallback = dt(2026, 7, 15, 13, 0, 0)
        self.assertEqual(availability.recovery([], fallback), fallback)

    def test_recovery_falls_back_when_down_for_entire_window(self):
        # Down through the whole series with no subsequent "up" datapoint:
        # there is nothing to anchor a real recovery to, so it must fall back
        # rather than fabricating a recovery time.
        series = [
            (dt(2026, 7, 15, 12, 0, 0), 0),
            (dt(2026, 7, 15, 12, 1, 0), 0),
            (dt(2026, 7, 15, 12, 2, 0), 0),
        ]
        fallback = dt(2026, 7, 15, 13, 0, 0)
        self.assertEqual(availability.recovery(series, fallback), fallback)


class BotoConfigTests(unittest.TestCase):
    """Every module-level client carries the bounded-timeout config."""

    def test_clients_share_bounded_config(self):
        try:
            with (
                mock.patch("botocore.config.Config") as config_cls,
                mock.patch("boto3.client") as client,
            ):
                importlib.reload(availability)
        finally:
            importlib.reload(availability)

        config_cls.assert_called_once_with(
            connect_timeout=3,
            read_timeout=8,
            retries={"max_attempts": 2, "mode": "standard"},
        )
        self.assertEqual(
            {c.args[0] for c in client.call_args_list},
            {
                "cloudwatch",
                "ec2",
                "autoscaling",
                "codedeploy",
                "ssm",
                "sns",
                "logs",
            },
        )
        for call in client.call_args_list:
            self.assertIs(call.kwargs["config"], config_cls.return_value)


if __name__ == "__main__":
    unittest.main()
