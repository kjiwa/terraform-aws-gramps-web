"""Replay suite for the class "every episode carries the cause of the event
that produced it". Each test replays one synthetic-but-faithful sequence of
AWS records through handle_down (at the alarm's ALARM time) and
handle_recovered (at its OK time) against an in-memory AWS whose history is
visible only up to the replay clock, then asserts the episode's cause and
`planned`. Shapes (deployment creators, scaling-activity wording, marker
timing) follow what the real account's APIs return; ids are placeholders.

Runnable: pytest test_availability_replay.py
"""

import datetime
import json
import types
import unittest
from unittest import mock

import test_availability as base

availability = base.availability
dt = base.dt
iso = base.iso

BASE = dt(2026, 9, 15, 10, 0, 0)
OLD_ID = "i-0000000000000001"
NEW_ID = "i-0000000000000002"

CAUSE_UNHEALTHY = "an instance was launched in response to an unhealthy instance needing to be replaced."
CAUSE_USER_HEALTH = (
    "an instance was taken out of service in response to a user health-check."
)
CAUSE_EC2_HEALTH = "an instance was taken out of service in response to an EC2 health check indicating it has been terminated or stopped."
CAUSE_REFRESH_OUT = (
    "an instance was taken out of service in response to an instance refresh."
)
CAUSE_REFRESH_IN = "an instance was launched in response to an instance refresh."
CAUSE_DESIRED_SET = "a user request explicitly set group desired capacity changing the desired capacity from 1 to 0."
CAUSE_DESIRED_DIFF = "an instance was started in response to a difference between desired and actual capacity, increasing the capacity from 0 to 1."


def at(seconds):
    return BASE + datetime.timedelta(seconds=seconds)


class FakeParameterNotFound(Exception):
    pass


class World:
    """In-memory AWS. `clock` hides every record newer than the replay time."""

    def __init__(self, *, lifecycle="spot", spot_price="0.016300"):
        self.clock = BASE
        self.state = "{}"
        self.markers = {}
        self.deployments = []
        self.refreshes = []
        self.activities = []
        self.down = (BASE, BASE)
        self.new_launched = BASE
        self.lifecycle = lifecycle
        self.spot_price = spot_price
        self.spot_price_calls = []
        self.episodes = []
        self.emails = []
        self.ssm = self._ssm()
        self.codedeploy = self._codedeploy()
        self.autoscaling = self._autoscaling()
        self.ec2 = self._ec2()
        self.cloudwatch = self._cloudwatch()
        self.sns = mock.Mock(publish=self._publish)
        self.logs = mock.Mock(put_log_events=self._put_log_events)

    def outage(self, started_s, ended_s, launched_s=None):
        self.down = (at(started_s), at(ended_s))
        self.new_launched = at(launched_s if launched_s is not None else ended_s - 150)

    def marker(self, param, written_s, **extra):
        self.markers[param] = (at(written_s), {"time": iso(at(written_s)), **extra})

    def deployment(self, created_s, creator):
        self.deployments.append(
            {
                "deploymentId": f"d-{len(self.deployments):09d}",
                "createTime": at(created_s),
                "creator": creator,
                "status": "Succeeded",
            }
        )

    def refresh(self, start_s):
        self.refreshes.append({"StartTime": at(start_s), "Status": "Successful"})

    def activity(self, start_s, description, cause):
        self.activities.append(
            {"Description": description, "Cause": cause, "StartTime": at(start_s)}
        )

    def terminating(self, start_s, cause):
        self.activity(
            start_s,
            f"Terminating EC2 instance: {OLD_ID}",
            f"At {iso(at(start_s))} {cause}",
        )

    def launching(self, start_s, cause):
        self.activity(
            start_s,
            f"Launching a new EC2 instance: {NEW_ID}",
            f"At {iso(at(start_s))} {cause}",
        )

    def _visible(self, when):
        return when <= self.clock

    def _ssm(self):
        world = self

        class Ssm:
            exceptions = types.SimpleNamespace(ParameterNotFound=FakeParameterNotFound)

            def get_parameter(self, Name):
                if Name == availability.STATE_PARAM:
                    return {"Parameter": {"Value": world.state}}
                written, value = world.markers.get(Name, (None, {}))
                if written is None or not world._visible(written):
                    value = {}
                return {"Parameter": {"Value": json.dumps(value)}}

            def put_parameter(self, Name, Value, **_):
                assert Name == availability.STATE_PARAM
                world.state = Value

        return Ssm()

    def _codedeploy(self):
        world = self

        class CodeDeploy:
            def list_deployments(self, createTimeRange, **_):
                return {
                    "deployments": [
                        d["deploymentId"]
                        for d in world.deployments
                        if createTimeRange["start"]
                        <= d["createTime"]
                        <= createTimeRange["end"]
                        and world._visible(d["createTime"])
                    ]
                }

            def batch_get_deployments(self, deploymentIds):
                return {
                    "deploymentsInfo": [
                        d
                        for d in world.deployments
                        if d["deploymentId"] in deploymentIds
                    ]
                }

        return CodeDeploy()

    def _autoscaling(self):
        world = self

        class Autoscaling:
            def describe_instance_refreshes(self, **_):
                return {
                    "InstanceRefreshes": [
                        r for r in world.refreshes if world._visible(r["StartTime"])
                    ]
                }

            def describe_scaling_activities(self, MaxRecords=100, **_):
                seen = [a for a in world.activities if world._visible(a["StartTime"])]
                seen.sort(key=lambda a: a["StartTime"], reverse=True)
                return {"Activities": seen[:MaxRecords]}

            def describe_auto_scaling_groups(self, **_):
                return {"AutoScalingGroups": [{"Instances": [{"InstanceId": NEW_ID}]}]}

        return Autoscaling()

    def _ec2(self):
        world = self

        class Ec2:
            def describe_instances(self, InstanceIds):
                launched = (
                    world.new_launched if InstanceIds[0] == NEW_ID else at(-86400)
                )
                instance = {
                    "InstanceType": "m8g.medium",
                    "Placement": {"AvailabilityZone": "us-east-1b"},
                    "Architecture": "arm64",
                    "LaunchTime": launched,
                }
                if world.lifecycle == "spot":
                    instance["InstanceLifecycle"] = "spot"
                return {"Reservations": [{"Instances": [instance]}]}

            def describe_spot_price_history(self, **kwargs):
                world.spot_price_calls.append(kwargs)
                if world.spot_price is None:
                    raise RuntimeError("throttled")
                return {"SpotPriceHistory": [{"SpotPrice": world.spot_price}]}

        return Ec2()

    def _cloudwatch(self):
        world = self

        class CloudWatch:
            def get_metric_data(self, StartTime, EndTime, **_):
                started, ended = world.down
                stamps, values = [], []
                t = StartTime.replace(second=0, microsecond=0)
                while t <= EndTime and world._visible(t):
                    stamps.append(t)
                    values.append(0 if started <= t < ended else 1)
                    t += datetime.timedelta(minutes=1)
                return {"MetricDataResults": [{"Timestamps": stamps, "Values": values}]}

        return CloudWatch()

    def _publish(self, TopicArn, Subject, Message):
        self.emails.append((Subject, Message))

    def _put_log_events(self, logEvents, **_):
        self.episodes.extend(json.loads(e["message"]) for e in logEvents)

    def patches(self):
        return [
            mock.patch.object(availability, name, getattr(self, name))
            for name in (
                "ssm",
                "codedeploy",
                "autoscaling",
                "ec2",
                "cloudwatch",
                "sns",
                "logs",
            )
        ]

    def warn(self, warned_s):
        self.clock = at(warned_s)
        availability.handle_interruption(
            {
                "time": iso(at(warned_s)),
                "detail": {"instance-id": OLD_ID, "instance-action": "terminate"},
            }
        )

    def replay(self, lag_s=180):
        started, _ended = self.down
        self.clock = started + datetime.timedelta(seconds=lag_s)
        availability.handle_down(
            {"state": {"value": "ALARM", "timestamp": iso(self.clock)}}
        )
        self.recover(lag_s)

    def recover(self, lag_s=180):
        started, ended = self.down
        self.clock = ended + datetime.timedelta(seconds=lag_s)
        availability.handle_recovered(
            {
                "state": {"value": "OK", "timestamp": iso(self.clock)},
                "previousState": {
                    "value": "ALARM",
                    "timestamp": iso(started + datetime.timedelta(seconds=lag_s)),
                },
            }
        )


class ReplayCase(unittest.TestCase):
    def setUp(self):
        self.world = World()
        self.world.outage(300, 600)
        for p in self.world.patches():
            p.start()
            self.addCleanup(p.stop)

    def assertEpisode(self, cause, planned):
        self.assertEqual(len(self.world.episodes), 1, self.world.emails)
        episode = self.world.episodes[0]
        self.assertEqual((episode["cause"], episode["planned"]), (cause, planned))
        return episode


class SpotReclaimReplay(ReplayCase):
    def test_a_warning_then_outage(self):
        self.world.outage(360, 720)
        self.world.warn(298)
        self.world.replay()
        self.assertEpisode("spot-reclaim", False)

    def test_a_warning_later_than_floored_start(self):
        self.world.outage(300, 660)
        self.world.warn(330)
        self.world.replay()
        self.assertEpisode("spot-reclaim", False)

    def test_a_missed_warning_with_autoscaling_deployment_is_not_deploy(self):
        self.world.terminating(330, CAUSE_EC2_HEALTH)
        self.world.launching(345, CAUSE_UNHEALTHY)
        self.world.deployment(450, "autoscaling")
        self.world.replay()
        self.assertEpisode("health-replace", False)


class WatchdogMarkerReplay(ReplayCase):
    def test_b_rightsize_marker_written_after_app_stopped(self):
        self.world.marker(availability.LAST_RIGHTSIZE_PARAM, 345, instance_id=OLD_ID)
        self.world.terminating(350, CAUSE_USER_HEALTH)
        self.world.launching(360, CAUSE_UNHEALTHY)
        self.world.replay()
        self.assertEpisode("rightsize", True)

    def test_b_health_watchdog_marker_written_after_threshold(self):
        self.world.outage(300, 1140)
        self.world.marker(
            availability.LAST_HEALTH_WATCHDOG_PARAM, 990, instance_id=OLD_ID
        )
        self.world.terminating(995, CAUSE_USER_HEALTH)
        self.world.launching(1005, CAUSE_UNHEALTHY)
        self.world.replay()
        self.assertEpisode("health-watchdog", False)


class DeploymentReplay(ReplayCase):
    def test_c_autoscaling_deployment_alone_is_not_deploy(self):
        self.world.deployment(450, "autoscaling")
        self.world.replay()
        self.assertEpisode("unknown", False)

    def test_c_autoscaling_deployment_after_health_replacement(self):
        self.world.terminating(330, CAUSE_USER_HEALTH)
        self.world.launching(345, CAUSE_UNHEALTHY)
        self.world.deployment(450, "autoscaling")
        self.world.replay()
        self.assertEpisode("health-replace", False)

    def test_d_user_deployment(self):
        self.world.deployment(270, "user")
        self.world.replay()
        self.assertEpisode("deploy", True)

    def test_d_rollback_deployment(self):
        self.world.deployment(270, "codeDeployRollback")
        self.world.replay()
        self.assertEpisode("deploy", True)

    def test_e_instance_refresh_with_autoscaling_deployment(self):
        self.world.refresh(285)
        self.world.terminating(290, CAUSE_REFRESH_OUT)
        self.world.launching(300, CAUSE_REFRESH_IN)
        self.world.deployment(480, "autoscaling")
        self.world.replay()
        self.assertEpisode("instance-refresh", True)


class ScalingActivityReplay(ReplayCase):
    def test_f_health_replacement_without_marker(self):
        self.world.terminating(330, CAUSE_USER_HEALTH)
        self.world.launching(345, CAUSE_UNHEALTHY)
        self.world.replay()
        self.assertEpisode("health-replace", False)

    def test_g_desired_capacity_change(self):
        self.world.terminating(290, CAUSE_DESIRED_SET)
        self.world.launching(310, CAUSE_DESIRED_DIFF)
        self.world.replay()
        self.assertEpisode("capacity-change", True)

    def test_g_launch_without_desired_capacity_change_is_not_capacity_change(self):
        self.world.launching(310, CAUSE_DESIRED_DIFF)
        self.world.replay()
        self.assertEpisode("unknown", False)


class BackupReplay(ReplayCase):
    def test_h_snapshot_marker(self):
        self.world.outage(300, 360)
        self.world.marker(availability.LAST_BACKUP_SNAPSHOT_PARAM, 255)
        self.world.replay(lag_s=120)
        self.assertEpisode("backup", True)


class WakeReplay(ReplayCase):
    def test_i_wake_with_no_open_outage_records_no_episode(self):
        self.world.recover()
        self.assertEqual(self.world.episodes, [])
        self.assertEqual(len(self.world.emails), 1)
        self.assertIn("woke", self.world.emails[0][0])


class ClassifiedAtRecovery(ReplayCase):
    def test_j_evidence_arriving_after_down_decides_the_episode(self):
        self.world.outage(300, 1140)
        self.world.marker(
            availability.LAST_HEALTH_WATCHDOG_PARAM, 990, instance_id=OLD_ID
        )
        self.world.replay()
        self.assertEpisode("health-watchdog", False)
        self.assertEqual(self.world.emails[0][0], "[gramps-web] DOWN - cause unknown")

    def test_j_user_deployment_created_during_outage(self):
        self.world.deployment(520, "user")
        self.world.replay()
        self.assertEpisode("deploy", True)


class EpisodeFieldsReplay(ReplayCase):
    def test_capacity_wait_and_boot_to_serve(self):
        self.world.outage(300, 600, launched_s=450)
        self.world.replay()
        episode = self.world.episodes[0]
        self.assertEqual(episode["capacity_wait_s"], 150)
        self.assertEqual(episode["boot_to_serve_s"], 150)

    def test_launch_before_start_clamps_wait_to_zero(self):
        self.world.outage(300, 600, launched_s=240)
        self.world.replay()
        self.assertEqual(self.world.episodes[0]["capacity_wait_s"], 0)

    def test_launch_after_end_clamps_boot_to_zero(self):
        self.world.outage(300, 600, launched_s=660)
        self.world.replay()
        self.assertEqual(self.world.episodes[0]["boot_to_serve_s"], 0)

    def test_spot_instance_records_price_at_launch(self):
        self.world.replay()
        episode = self.world.episodes[0]
        self.assertEqual(episode["lifecycle"], "spot")
        self.assertEqual(episode["spot_price"], 0.0163)
        call = self.world.spot_price_calls[0]
        self.assertEqual(call["StartTime"], call["EndTime"])
        self.assertEqual(call["StartTime"], self.world.new_launched)
        self.assertEqual(call["InstanceTypes"], ["m8g.medium"])
        self.assertEqual(call["AvailabilityZone"], "us-east-1b")

    def test_on_demand_instance_has_no_price_and_no_lookup(self):
        self.world.lifecycle = "on-demand"
        self.world.replay()
        episode = self.world.episodes[0]
        self.assertEqual(episode["lifecycle"], "on-demand")
        self.assertIsNone(episode["spot_price"])
        self.assertEqual(self.world.spot_price_calls, [])

    def test_price_lookup_failure_degrades_to_null(self):
        self.world.spot_price = None
        self.world.replay()
        self.assertIsNone(self.world.episodes[0]["spot_price"])


if __name__ == "__main__":
    unittest.main()
