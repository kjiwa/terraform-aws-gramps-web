"""Change log: deployment and instance-refresh completion events become one
JSON line each in the `changes` stream, whether or not the site went down.
Runs the handler against fake CodeDeploy/CodePipeline/Auto Scaling/Logs.

Runnable: pytest test_availability_changes.py
"""

import contextlib
import io
import json
import unittest
from unittest import mock

import test_availability as base

availability = base.availability
dt = base.dt
iso = base.iso

CREATED = dt(2026, 9, 15, 10, 0, 0)
COMPLETED = dt(2026, 9, 15, 10, 4, 30)
EVENT_TIME = "2026-09-15T10:04:35Z"
DEPLOYMENT_ID = "d-AAAAAAAAA"
REFRESH_ID = "11111111-2222-3333-4444-555555555555"
DEPLOY_TYPE = "CodeDeploy Deployment State-change Notification"
REFRESH_TYPE = "EC2 Auto Scaling Instance Refresh "


def deploy_event(state, deployment_id=DEPLOYMENT_ID):
    return {
        "detail-type": DEPLOY_TYPE,
        "time": EVENT_TIME,
        "detail": {
            "application": "test-app",
            "deploymentGroup": "test-group",
            "deploymentId": deployment_id,
            "state": state,
        },
    }


def refresh_event(suffix):
    return {
        "detail-type": REFRESH_TYPE + suffix,
        "time": EVENT_TIME,
        "detail": {"InstanceRefreshId": REFRESH_ID, "AutoScalingGroupName": "test-asg"},
    }


class FakeAws:
    def __init__(self):
        self.deployments = {
            DEPLOYMENT_ID: {
                "deploymentId": DEPLOYMENT_ID,
                "creator": "user",
                "createTime": CREATED,
                "completeTime": COMPLETED,
                "description": "ship it",
            }
        }
        self.refreshes = {
            REFRESH_ID: {
                "InstanceRefreshId": REFRESH_ID,
                "StartTime": CREATED,
                "EndTime": COMPLETED,
                "StatusReason": "done",
            }
        }
        self.fail = set()
        self.puts = []

    def get_deployment(self, deploymentId):
        if "get_deployment" in self.fail:
            raise RuntimeError("throttled")
        return {"deploymentInfo": self.deployments[deploymentId]}

    def batch_get_deployments(self, deploymentIds):
        return {
            "deploymentsInfo": [
                self.deployments[i] for i in deploymentIds if i in self.deployments
            ]
        }

    def describe_instance_refreshes(self, AutoScalingGroupName, InstanceRefreshIds):
        if "refresh" in self.fail:
            raise RuntimeError("throttled")
        return {
            "InstanceRefreshes": [
                self.refreshes[i] for i in InstanceRefreshIds if i in self.refreshes
            ]
        }

    def put_log_events(self, logGroupName, logStreamName, logEvents):
        if "put" in self.fail:
            raise RuntimeError("logs down")
        self.puts.append((logGroupName, logStreamName, logEvents))


class ChangeCase(unittest.TestCase):
    def setUp(self):
        self.aws = FakeAws()
        for name in ("codedeploy", "autoscaling", "logs"):
            patcher = mock.patch.object(availability, name, self.aws)
            patcher.start()
            self.addCleanup(patcher.stop)

    def records(self):
        return [
            json.loads(e["message"]) for _, _, events in self.aws.puts for e in events
        ]


class DeployChangeTests(ChangeCase):
    def test_success_records_the_enriched_deployment(self):
        availability.handler(deploy_event("SUCCESS"), None)
        group, stream, events = self.aws.puts[0]
        self.assertEqual(
            (group, stream), (availability.EPISODES_LOG_GROUP, "test-changes-stream")
        )
        self.assertEqual(
            json.loads(events[0]["message"]),
            {
                "at": "2026-09-15T10:04:30Z",
                "kind": "deploy",
                "id": DEPLOYMENT_ID,
                "creator": "user",
                "outcome": "succeeded",
                "duration_s": 270,
                "description": "ship it",
            },
        )

    def test_state_maps_to_outcome(self):
        for state, outcome in [
            ("SUCCESS", "succeeded"),
            ("FAILURE", "failed"),
            ("STOP", "stopped"),
        ]:
            self.aws.puts.clear()
            availability.handler(deploy_event(state), None)
            self.assertEqual(self.records()[0]["outcome"], outcome)

    def test_in_flight_states_write_nothing(self):
        for state in ("START", "QUEUED", "READY"):
            availability.handler(deploy_event(state), None)
        self.assertEqual(self.aws.puts, [])

    def test_autoscaling_deployments_are_kept(self):
        self.aws.deployments[DEPLOYMENT_ID]["creator"] = "autoscaling"
        availability.handler(deploy_event("SUCCESS"), None)
        self.assertEqual(self.records()[0]["creator"], "autoscaling")

    def test_enrichment_failure_falls_back_to_the_event(self):
        self.aws.fail.add("get_deployment")
        availability.handler(deploy_event("FAILURE"), None)
        self.assertEqual(
            self.records()[0],
            {
                "at": EVENT_TIME,
                "kind": "deploy",
                "id": DEPLOYMENT_ID,
                "creator": None,
                "outcome": "failed",
                "duration_s": None,
                "description": None,
            },
        )

    def test_write_failure_raises_so_delivery_retries(self):
        self.aws.fail.add("put")
        with self.assertRaises(RuntimeError):
            availability.handler(deploy_event("SUCCESS"), None)


class RefreshChangeTests(ChangeCase):
    def test_outcome_per_detail_type(self):
        for suffix, outcome in [
            ("Succeeded", "succeeded"),
            ("Failed", "failed"),
            ("Cancelled", "cancelled"),
            ("Rollback Succeeded", "rollback-succeeded"),
            ("Rollback Failed", "rollback-failed"),
        ]:
            self.aws.puts.clear()
            availability.handler(refresh_event(suffix), None)
            self.assertEqual(self.records()[0]["outcome"], outcome, suffix)

    def test_success_records_the_enriched_refresh(self):
        availability.handler(refresh_event("Succeeded"), None)
        self.assertEqual(
            self.records()[0],
            {
                "at": "2026-09-15T10:04:30Z",
                "kind": "instance-refresh",
                "id": REFRESH_ID,
                "creator": None,
                "outcome": "succeeded",
                "duration_s": 270,
                "description": "done",
            },
        )

    def test_in_flight_events_write_nothing(self):
        for suffix in ("Started", "Checkpoint Reached", "Rollback Started"):
            availability.handler(refresh_event(suffix), None)
        self.assertEqual(self.aws.puts, [])

    def test_enrichment_failure_falls_back_to_the_event(self):
        self.aws.fail.add("refresh")
        availability.handler(refresh_event("Failed"), None)
        record = self.records()[0]
        self.assertEqual((record["at"], record["duration_s"]), (EVENT_TIME, None))

    def test_unknown_refresh_logs_not_found_and_still_records(self):
        self.aws.refreshes.clear()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            availability.handler(refresh_event("Succeeded"), None)
        self.assertIn("instance_refresh_not_found", out.getvalue())
        self.assertNotIn("describe_instance_refreshes_failed", out.getvalue())
        record = self.records()[0]
        self.assertEqual(
            (record["at"], record["duration_s"], record["description"]),
            (EVENT_TIME, None, None),
        )


class RedeliveryTests(ChangeCase):
    def test_a_redelivered_event_writes_an_identical_line(self):
        availability.handler(deploy_event("SUCCESS"), None)
        availability.handler(deploy_event("SUCCESS"), None)
        first, second = [events[0] for _, _, events in self.aws.puts]
        self.assertEqual(first, second)
        self.assertEqual(
            first["timestamp"], int(dt(2026, 9, 15, 10, 4, 35).timestamp() * 1000)
        )


if __name__ == "__main__":
    unittest.main()
