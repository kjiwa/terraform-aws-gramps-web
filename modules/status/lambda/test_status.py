"""Pure-function tests for the reliability strip's alignment fix (floor_utc,
grid_cells, cell_label, RANGES). No AWS dependency: boto3/botocore are
stubbed out below before status.py is imported, so this never needs
credentials, a region, or network access -- only status.py's module-level
`boto3.client(...)` calls need to not blow up at import time.

Runnable two ways:
    pytest test_status.py
    python3 test_status.py
"""

import datetime
import json
import os
import sys
import types
import unittest
from unittest import mock

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

# --- stub boto3/botocore so importing status.py makes zero AWS calls and
# needs no region/credentials -- this is what "no AWS dependency" means for a
# module that creates its clients at import time. --------------------------

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

# status.py reads these via os.environ[...] (no default) at module level.
for _var, _val in [
    ("SITE_URL", "https://example.invalid"),
    ("MIN_ROLE", "owner"),
    ("ASG_NAME", "test-asg"),
    ("CODEDEPLOY_APP_NAME", "test-app"),
    ("CODEDEPLOY_DEPLOYMENT_GROUP", "test-group"),
    ("DELIBERATE_DEPLOYMENT_CREATORS", "user,codeDeployRollback"),
    ("CODEPIPELINE_NAME", "test-pipeline"),
    ("SOURCE_REPO", "example/gramps-web"),
    ("ECR_REPO_NAME", "test-repo"),
    ("EBS_VOLUME_ID", "vol-test"),
    ("MEDIA_BUCKET_NAME", "test-bucket"),
    ("EPISODES_LOG_GROUP", "test-log-group"),
    ("EPISODES_LOG_STREAM", "test-log-stream"),
    ("CHANGES_LOG_STREAM", "test-changes-stream"),
    ("SPOT_INTERRUPTIONS_LOG_GROUP", "test-spot-group"),
    ("SITEUP_METRIC_NAMESPACE", "test/SiteUp"),
]:
    os.environ.setdefault(_var, _val)

import status

UTC = datetime.UTC


def dt(*args):
    return datetime.datetime(*args, tzinfo=UTC)


class FloorUtcTests(unittest.TestCase):
    def test_floors_to_day(self):
        self.assertEqual(
            status.floor_utc(dt(2026, 7, 15, 18, 6, 30), 86400),
            dt(2026, 7, 15, 0, 0, 0),
        )

    def test_floors_to_hour(self):
        self.assertEqual(
            status.floor_utc(dt(2026, 7, 15, 18, 6, 30), 3600),
            dt(2026, 7, 15, 18, 0, 0),
        )

    def test_exact_multiple_is_unchanged(self):
        self.assertEqual(
            status.floor_utc(dt(2026, 7, 15, 0, 0, 0), 86400), dt(2026, 7, 15, 0, 0, 0)
        )


class GridCellsRegressionTests(unittest.TestCase):
    """A synthetic outage stamped 2026-07-15T18:06Z lands in the cell labeled
    "2026-07-15", not the previous day's.
    """

    def test_outage_lands_in_correct_calendar_cell(self):
        # A daily (period_s=86400) CloudWatch datapoint is stamped at its
        # bucket's *start*; a query floored to whole UTC days (as
        # reliability() now does) stamps the bucket covering an 18:06Z
        # outage at that day's midnight, not the previous day's.
        outage_bucket_start = dt(2026, 7, 15, 0, 0, 0)
        series = [(outage_bucket_start, 0.95486, 1400)]

        width_s = 86400
        count = 10
        strip_end = dt(2026, 7, 20, 0, 0, 0)
        strip_start = strip_end - count * datetime.timedelta(seconds=width_s)

        cells = status.grid_cells(series, strip_start, width_s, count)
        matches = [c for c in cells if c["label"] == "2026-07-15"]
        self.assertEqual(
            len(matches),
            1,
            f"expected exactly one cell labeled 2026-07-15, got: {[c['label'] for c in cells]}",
        )
        self.assertAlmostEqual(matches[0]["avg"], 0.95486)
        self.assertEqual(matches[0]["samples"], 1400)


class GridCellsAlignmentTests(unittest.TestCase):
    """On a fully-covered 90d strip, cell 0 and cell 1 have equal samples
    (1440). Catches an int()-truncation double-count (a datapoint just
    before the window start mapping into cell 0 instead of being dropped)
    and any future misalignment.
    """

    def test_cell_0_and_cell_1_equal_samples(self):
        spec = status.RANGES["90d"]
        width_s = spec["cell_s"]
        count = spec["cells"]
        self.assertEqual(width_s, 86400)

        strip_end = dt(2026, 10, 1, 0, 0, 0)
        strip_start = strip_end - count * datetime.timedelta(seconds=width_s)

        # One full day (1440 one-minute canary samples) per daily bucket,
        # covering the whole strip plus margin on both sides -- "fully
        # covered."
        series = []
        ts = strip_start - datetime.timedelta(days=2)
        while ts < strip_end + datetime.timedelta(days=2):
            series.append((ts, 1.0, 1440))
            ts += datetime.timedelta(days=1)

        cells = status.grid_cells(series, strip_start, width_s, count)
        self.assertEqual(cells[0]["samples"], 1440)
        self.assertEqual(cells[1]["samples"], 1440)
        self.assertEqual(cells[0]["samples"], cells[1]["samples"])
        # And, since coverage is total, every cell should agree.
        self.assertTrue(all(c["samples"] == 1440 for c in cells))


class RangesCoverageTests(unittest.TestCase):
    """Every range's strip can never reach before its own query's start, so
    nobody can bump `cells` (e.g. 1y to 53) and silently push `strip_start`
    before `qstart`.

    Note on the bound used here: reliability()'s query() floors to
    `period_s` (not `cell_s`) and then subtracts one further `period_s` of
    slack -- see status.py's query() closure. Bounding floor_utc()'s slop on
    both sides (strip_end's align-rounding and qstart's period_s-rounding)
    gives the tight, `now`-independent sufficient condition
    `cells * cell_s <= query_days * 86400 + period_s`. This is a `period_s`
    bound, not a `cell_s` one: cell_s only ever appears once, on the left.
    Checked against the actual RANGES table, 24h/7d have zero slack margin
    at all (cells * cell_s == query_days * 86400 exactly) and 1y has ~2
    days -- exactly enough for one extra period_s but nowhere near two extra
    cell_s, which is why a `- 2 * cell_s` formulation cannot hold for any of
    24h/7d/1y against this table.
    """

    def test_strip_never_precedes_query_start(self):
        for key, spec in status.RANGES.items():
            cells, cell_s, period_s, query_days = (
                spec["cells"],
                spec["cell_s"],
                spec["period_s"],
                spec["query_days"],
            )
            with self.subTest(range=key):
                self.assertLessEqual(cells * cell_s, query_days * 86400 + period_s)

    def test_bumping_1y_cells_would_break_the_margin(self):
        # 52 -> 53 weekly cells for 1y should push the strip span past what
        # the 365-day query covers.
        spec = status.RANGES["1y"]
        bumped_cells = spec["cells"] + 1
        self.assertGreater(
            bumped_cells * spec["cell_s"], spec["query_days"] * 86400 + spec["period_s"]
        )


class PartialCellTests(unittest.TestCase):
    """4. 24h's trailing cell is flagged partial and the other 23 are not."""

    def test_only_trailing_24h_cell_is_partial(self):
        spec = status.RANGES["24h"]
        cell_s = spec["cell_s"]
        count = spec["cells"]
        align = min(cell_s, 86400)

        now = datetime.datetime.now(UTC)
        strip_end = status.floor_utc(now, align) + datetime.timedelta(seconds=align)
        strip_start = strip_end - count * datetime.timedelta(seconds=cell_s)

        cells = status.grid_cells([], strip_start, cell_s, count)
        self.assertEqual(len(cells), 24)
        partial_flags = [c["partial"] for c in cells]
        self.assertEqual(
            sum(partial_flags),
            1,
            f"expected exactly one partial cell, got flags: {partial_flags}",
        )
        self.assertTrue(
            partial_flags[-1], "the trailing (last) cell should be the partial one"
        )
        self.assertFalse(
            any(partial_flags[:-1]), "no cell before the trailing one should be partial"
        )


class GridCellsExpectedSamplesTests(unittest.TestCase):
    """expected_samples is inferred from this call's own complete
    (non-partial) buckets rather than a fixed width // 60s-cadence formula.
    The rate used below (20 samples/900s, i.e. one every 45s) is
    deliberately not 1/minute, so a correct result here is proof the
    inference is genuinely rate-derived: a fixed-60s formula would answer
    width // 60 == 3600 // 60 == 60, not 80.
    """

    def test_expected_samples_matches_a_non_canonical_observed_rate(self):
        strip_start = dt(2026, 7, 15, 0, 0, 0)
        width_s = 3600
        count = 5
        raw_period_s = 900

        # Hours 0-3: fully complete, 4 raw 15-minute datapoints of 20 samples
        # each -> 80 samples/hour. Hour 4: only the :00 and :15 sub-periods
        # have happened yet by the frozen "now" below, so it stays partial
        # with 40 of the 80 samples a complete hour would carry.
        series = []
        ts = strip_start
        while ts < strip_start + datetime.timedelta(hours=4):
            series.append((ts, 1.0, 20))
            ts += datetime.timedelta(seconds=raw_period_s)
        series.append((dt(2026, 7, 15, 4, 0, 0), 1.0, 20))
        series.append((dt(2026, 7, 15, 4, 15, 0), 1.0, 20))

        fixed_now = dt(2026, 7, 15, 4, 30, 0)

        class FrozenDatetime(datetime.datetime):
            @classmethod
            def now(cls, tz=None):
                return fixed_now if tz is None else fixed_now.astimezone(tz)

        with mock.patch.object(status.datetime, "datetime", FrozenDatetime):
            cells = status.grid_cells(series, strip_start, width_s, count)

        self.assertEqual([c["samples"] for c in cells], [80, 80, 80, 80, 40])
        self.assertEqual(
            [c["partial"] for c in cells], [False, False, False, False, True]
        )
        # One shared value for the whole call, including the partial cell --
        # expected_samples describes a fully-covered cell's target, not that
        # cell's own (necessarily lower, still-filling) count.
        self.assertTrue(all(c["expected_samples"] == 80 for c in cells))

    def test_expected_samples_is_none_when_no_complete_bucket_has_data(self):
        # A brand-new range: only the still-filling first cell has any data
        # at all, so there is no complete bucket to infer a rate from.
        strip_start = dt(2026, 7, 15, 0, 0, 0)
        width_s = 3600
        count = 3
        series = [(dt(2026, 7, 15, 0, 0, 0), 1.0, 20)]
        fixed_now = dt(2026, 7, 15, 0, 30, 0)

        class FrozenDatetime(datetime.datetime):
            @classmethod
            def now(cls, tz=None):
                return fixed_now if tz is None else fixed_now.astimezone(tz)

        with mock.patch.object(status.datetime, "datetime", FrozenDatetime):
            cells = status.grid_cells(series, strip_start, width_s, count)

        self.assertTrue(all(c["expected_samples"] is None for c in cells))


class CellLabelTests(unittest.TestCase):
    def test_week_span_label(self):
        # 7-day (604800s) cells: a plain date range, not "week of" -- these
        # are day-anchored spans that slide daily, not calendar weeks.
        label = status.cell_label(dt(2026, 7, 13, 0, 0, 0), 604800)
        self.assertEqual(label, "2026-07-13 – 2026-07-19")

    def test_day_label(self):
        label = status.cell_label(dt(2026, 7, 15, 0, 0, 0), 86400)
        self.assertEqual(label, "2026-07-15")

    def test_sub_day_label_includes_date(self):
        label = status.cell_label(dt(2026, 7, 15, 14, 0, 0), 3600)
        self.assertEqual(label, "2026-07-15 14:00")


class WeightedUptimeTests(unittest.TestCase):
    """weighted_uptime(series, start, end, period_s, exclude_windows) --
    sample-weighted uptime over [start, end) from (ts, avg, samples)
    datapoints. Regression coverage for the int()-truncation double-count bug
    the module docstring references: computing a per-bucket fraction with a
    truncating int() (rather than true division) either zeroes out a partial
    overlap or rounds it up to a whole bucket, so a straddling window would
    either drop a real bucket's contribution or count more than the window
    actually spans. These tests assert the exact numeric result, which an
    int()-truncated fraction would miss.
    """

    def test_window_fully_inside_one_cell(self):
        # A single daily bucket (period_s=86400); the query window covers only
        # the middle half of it (12h of 24h), so weighted_uptime must weight by
        # the overlap fraction (0.5), not treat the whole bucket as in-window.
        bucket_start = dt(2026, 7, 15, 0, 0, 0)
        series = [(bucket_start, 0.5, 1440)]
        start = dt(2026, 7, 15, 6, 0, 0)
        end = dt(2026, 7, 15, 18, 0, 0)

        result = status.weighted_uptime(series, start, end, 86400)
        self.assertEqual(result, 50.0)

    def test_window_straddling_a_cell_boundary(self):
        # Two adjacent daily buckets; the window spans the last half of the
        # first (all-up) and the first half of the second (all-down). Each
        # bucket contributes exactly half its samples, weighted by its own
        # overlap fraction -- not double-counted and not dropped.
        day1 = dt(2026, 7, 15, 0, 0, 0)
        day2 = dt(2026, 7, 16, 0, 0, 0)
        series = [
            (day1, 1.0, 1440),
            (day2, 0.0, 1440),
        ]
        start = dt(2026, 7, 15, 12, 0, 0)
        end = dt(2026, 7, 16, 12, 0, 0)

        result = status.weighted_uptime(series, start, end, 86400)
        # weighted = (1.0*1440*0.5) + (0.0*1440*0.5) = 720; total = 1440*0.5 + 1440*0.5 = 1440
        self.assertEqual(result, 50.0)

    def test_none_when_no_overlap(self):
        series = [(dt(2026, 7, 15, 0, 0, 0), 1.0, 1440)]
        start = dt(2026, 7, 20, 0, 0, 0)
        end = dt(2026, 7, 21, 0, 0, 0)
        self.assertIsNone(status.weighted_uptime(series, start, end, 86400))

    def test_exclude_windows_removes_planned_maintenance_overlap(self):
        # Same straddling setup as above, but a planned-maintenance window
        # covers the last 6h of the first bucket's overlap with the query
        # window -- and that bucket is fully up (avg=1.0), so it has zero
        # down probes for the window to remove. Exclusion only ever drops
        # down probes now (not window-overlap time), so excluding planned
        # time that happened to be up gives no free credit: the result is
        # identical to the unexcluded straddling case above.
        day1 = dt(2026, 7, 15, 0, 0, 0)
        day2 = dt(2026, 7, 16, 0, 0, 0)
        series = [
            (day1, 1.0, 1440),
            (day2, 0.0, 1440),
        ]
        start = dt(2026, 7, 15, 12, 0, 0)
        end = dt(2026, 7, 16, 12, 0, 0)
        exclude_windows = [(dt(2026, 7, 15, 18, 0, 0), dt(2026, 7, 16, 0, 0, 0))]

        result = status.weighted_uptime(series, start, end, 86400, exclude_windows)
        # bucket1: fraction 0.5 -> up = 1.0*1440*0.5 = 720, seen = 720;
        #   0 down probes observed, so the 6h/360-probe exclusion clamps to 0.
        # bucket2: fraction 0.5 -> up = 0, seen = 720; window doesn't reach it.
        # uptime = 100 * 720 / 1440
        self.assertAlmostEqual(result, round(100 * 720 / 1440, 2))

    def test_exclude_window_covering_entire_bucket_overlap_drops_it(self):
        # Still None: all 1440 down probes are observed AND all 1440 are
        # planned, so seen is clamped
        # down to exactly 0 (min(1440, 1440)) rather than negative, and a
        # zero-sample bucket contributes nothing to either side of the ratio.
        series = [(dt(2026, 7, 15, 0, 0, 0), 0.0, 1440)]
        start = dt(2026, 7, 15, 0, 0, 0)
        end = dt(2026, 7, 16, 0, 0, 0)
        exclude_windows = [(dt(2026, 7, 15, 0, 0, 0), dt(2026, 7, 16, 0, 0, 0))]
        self.assertIsNone(
            status.weighted_uptime(series, start, end, 86400, exclude_windows)
        )

    def test_realistic_24h_outage_fully_excluded(self):
        # The reported live regression: a single 5-minute planned outage
        # (the ASG refresh deploy) inside an otherwise perfect 24h window,
        # queried at the 24h range's actual Period=300 -- so the outage
        # straddles two 5-sample buckets exactly as CloudWatch returned them:
        # 23:05Z (0.8, 5 samples) and 23:10Z (0.2, 5 samples).
        day_start = dt(2026, 8, 9, 0, 0, 0)
        period_s = 300
        series = []
        ts = day_start
        while ts < day_start + datetime.timedelta(days=1):
            if ts == dt(2026, 8, 9, 23, 5, 0):
                series.append((ts, 0.8, 5))
            elif ts == dt(2026, 8, 9, 23, 10, 0):
                series.append((ts, 0.2, 5))
            else:
                series.append((ts, 1.0, 5))
            ts += datetime.timedelta(seconds=period_s)
        self.assertEqual(len(series), 288)
        self.assertEqual(sum(samples for _, _, samples in series), 1440)

        start = day_start
        end = day_start + datetime.timedelta(days=1)
        exclude_windows = [(dt(2026, 8, 9, 23, 9, 0), dt(2026, 8, 9, 23, 14, 0))]

        # Raw: 5 down probes (1 in the 23:05Z bucket, 4 in the 23:10Z bucket)
        # out of 1440 -> 1435/1440, unrounded -- weighted_uptime() no longer
        # rounds itself (see reliability()'s render-time rounding).
        self.assertAlmostEqual(
            status.weighted_uptime(series, start, end, period_s), 100 * 1435 / 1440
        )
        # Excluding the planned window drops exactly those 5 down probes
        # (60s/1 probe from 23:05Z, 240s/4 probes from 23:10Z) -- no phantom
        # downtime left smeared in at partial weight.
        self.assertEqual(
            status.weighted_uptime(series, start, end, period_s, exclude_windows), 100.0
        )

    def test_coarse_period_planned_outage_fully_excluded(self):
        # Same 5-minute outage, but queried at Period=86400 (30d/90d/1y) --
        # a naive time-fraction scaling would handle this worst: a 5-minute
        # exclusion only ever discounts (1 - 300/86400) of the bucket's
        # weight, leaving ~4.98 of the 5 down-minutes as phantom downtime.
        day_start = dt(2026, 8, 9, 0, 0, 0)
        series = [(day_start, 1435 / 1440, 1440)]
        start = day_start
        end = day_start + datetime.timedelta(days=1)
        exclude_windows = [(dt(2026, 8, 9, 23, 9, 0), dt(2026, 8, 9, 23, 14, 0))]

        self.assertAlmostEqual(
            status.weighted_uptime(series, start, end, 86400), 100 * 1435 / 1440
        )
        self.assertEqual(
            status.weighted_uptime(series, start, end, 86400, exclude_windows), 100.0
        )

    def test_double_counted_overlap_does_not_over_subtract(self):
        # A single partially-down bucket (1 up, 4 down of 5 probes) covered
        # by two overlapping planned windows. excluded_overlap_s sums windows
        # independently (see its docstring), so their overlap with the
        # bucket is double-counted: 300s + 300s = 600s, or 10 probes'
        # worth -- more than the 4 down probes that actually occurred. The
        # min() clamp in weighted_uptime caps the subtraction at those 4,
        # leaving the bucket's one genuine up probe intact rather than
        # over-subtracting into a negative seen count.
        bucket_start = dt(2026, 7, 15, 0, 0, 0)
        series = [(bucket_start, 0.2, 5)]
        start = bucket_start
        end = bucket_start + datetime.timedelta(seconds=300)
        exclude_windows = [
            (bucket_start, end),
            (bucket_start, end),
        ]
        self.assertEqual(
            status.weighted_uptime(series, start, end, 300, exclude_windows), 100.0
        )


class WeightedUptimeCadenceInvarianceTests(unittest.TestCase):
    """Part 4: weighted_uptime()'s ratio is sample-weighted (up = avg *
    samples * fraction, seen = samples * fraction), so scaling every
    bucket's SampleCount by a constant factor must leave the computed
    uptime %% unchanged. This is what lets a canary cadence change (or,
    once Part 3 lands, a source switch) report correctly with no
    special-casing -- proven here with the same straddling-boundary shape
    as WeightedUptimeTests.test_window_straddling_a_cell_boundary, once at
    SampleCount=1 and once at SampleCount=6.
    """

    def test_sample_count_6_matches_sample_count_1_for_same_downtime(self):
        day1 = dt(2026, 7, 15, 0, 0, 0)
        day2 = dt(2026, 7, 16, 0, 0, 0)
        start = dt(2026, 7, 15, 12, 0, 0)
        end = dt(2026, 7, 16, 12, 0, 0)

        series_1x = [(day1, 1.0, 1), (day2, 0.0, 1)]
        series_6x = [(day1, 1.0, 6), (day2, 0.0, 6)]

        result_1x = status.weighted_uptime(series_1x, start, end, 86400)
        result_6x = status.weighted_uptime(series_6x, start, end, 86400)
        self.assertEqual(result_1x, result_6x)
        self.assertEqual(result_1x, 50.0)


class WeightedUptimeMixedCadenceExclusionTests(unittest.TestCase):
    """seen -= min(seen - up, planned_s * samples / period_s), rate-derived
    rather than planned_s / 60s (a hardcoded-cadence assumption). These
    buckets are deliberately not at a 1/min-equivalent rate, so a formula
    that assumed 60s would subtract the wrong number of samples.
    """

    def test_exclusion_correct_at_a_non_canonical_rate(self):
        # 360 samples/hour (6/min), i.e. one sample per 10s, not 60s. A
        # 2-minute (120s) exclusion at this rate is 12 samples; a
        # hardcoded-60s formula would read it as only 2 (120/60), leaving
        # 10 phantom down-samples uncancelled.
        bucket_start = dt(2026, 7, 15, 1, 0, 0)
        period_s = 3600
        series = [(bucket_start, 348 / 360, 360)]  # 12 of 360 down
        start = bucket_start
        end = bucket_start + datetime.timedelta(seconds=period_s)
        exclude_windows = [(dt(2026, 7, 15, 1, 10, 0), dt(2026, 7, 15, 1, 12, 0))]

        result = status.weighted_uptime(series, start, end, period_s, exclude_windows)
        self.assertEqual(result, 100.0)

    def test_mixed_cadence_series_excludes_each_era_at_its_own_rate(self):
        # The concrete case Part 4 exists for: SampleCount changes partway
        # through one series (a canary cadence change, or -- once Part 3
        # lands -- a source switch). Hour 1 is a 1/min-equivalent bucket (60
        # samples), hour 2 is 6/min (360 samples); each carries a 2-minute
        # planned window over exactly its own 2 down-minutes. A single
        # global rate (blended, or the retired hardcoded 60) cannot get both
        # right at once -- per-bucket inference (samples / period_s) does,
        # since each row of the series carries its own samples count.
        hour1 = dt(2026, 7, 15, 0, 0, 0)
        hour2 = dt(2026, 7, 15, 1, 0, 0)
        period_s = 3600
        series = [
            (hour1, 58 / 60, 60),  # 1/min era: 2 of 60 down
            (hour2, 348 / 360, 360),  # 6/min era: 12 of 360 down (same 2 real minutes)
        ]
        start = hour1
        end = hour2 + datetime.timedelta(seconds=period_s)
        exclude_windows = [
            (dt(2026, 7, 15, 0, 10, 0), dt(2026, 7, 15, 0, 12, 0)),
            (dt(2026, 7, 15, 1, 10, 0), dt(2026, 7, 15, 1, 12, 0)),
        ]

        result = status.weighted_uptime(series, start, end, period_s, exclude_windows)
        self.assertEqual(result, 100.0)


class ExcludedOverlapSTests(unittest.TestCase):
    """excluded_overlap_s(window_start, window_end, exclude_windows) -- total
    seconds of the window covered by exclude_windows, summed independently
    (not merged) per window.
    """

    def test_no_overlap_is_zero(self):
        window_start = dt(2026, 7, 15, 0, 0, 0)
        window_end = dt(2026, 7, 15, 12, 0, 0)
        exclude_windows = [(dt(2026, 7, 16, 0, 0, 0), dt(2026, 7, 16, 6, 0, 0))]
        self.assertEqual(
            status.excluded_overlap_s(window_start, window_end, exclude_windows), 0
        )

    def test_planned_maintenance_window_partially_overlaps(self):
        window_start = dt(2026, 7, 15, 0, 0, 0)
        window_end = dt(2026, 7, 15, 12, 0, 0)
        # Exclusion starts 2h before the window ends and runs 4h past it.
        exclude_windows = [(dt(2026, 7, 15, 10, 0, 0), dt(2026, 7, 15, 16, 0, 0))]
        self.assertEqual(
            status.excluded_overlap_s(window_start, window_end, exclude_windows),
            2 * 3600,
        )

    def test_exclusion_window_fully_inside_query_window(self):
        window_start = dt(2026, 7, 15, 0, 0, 0)
        window_end = dt(2026, 7, 15, 12, 0, 0)
        exclude_windows = [(dt(2026, 7, 15, 4, 0, 0), dt(2026, 7, 15, 6, 0, 0))]
        self.assertEqual(
            status.excluded_overlap_s(window_start, window_end, exclude_windows),
            2 * 3600,
        )

    def test_multiple_windows_summed_independently_not_merged(self):
        window_start = dt(2026, 7, 15, 0, 0, 0)
        window_end = dt(2026, 7, 15, 12, 0, 0)
        # Two overlapping exclusion windows, both intersecting the query
        # window over the same [4:00, 6:00) span. Per the docstring, overlaps
        # are summed per-window rather than merged first, so this double-counts
        # the shared span by design.
        exclude_windows = [
            (dt(2026, 7, 15, 4, 0, 0), dt(2026, 7, 15, 6, 0, 0)),
            (dt(2026, 7, 15, 4, 0, 0), dt(2026, 7, 15, 8, 0, 0)),
        ]
        self.assertEqual(
            status.excluded_overlap_s(window_start, window_end, exclude_windows),
            2 * 3600 + 4 * 3600,
        )


class LatencyCellsTests(unittest.TestCase):
    """latency_cells(series, start, width, count) -- bucketed p50/p90
    averages mirroring grid_cells()'s floor-division bucketing, but for
    latency instead of uptime.
    """

    def test_buckets_average_and_gaps_stay_none(self):
        start = dt(2026, 7, 15, 0, 0, 0)
        width_s = 3600
        count = 3
        series = [
            # Bucket 0: two latency points -- averaged.
            (start, 1.0, 60, 100.0, 200.0),
            (start + datetime.timedelta(minutes=30), 1.0, 60, 140.0, 260.0),
            # Bucket 1: a SiteUp datapoint exists (the probe ran) but carries
            # no latency at all -- e.g. every probe in this bucket failed
            # before an HTTP status came back. Must render None, not 0.
            (start + datetime.timedelta(hours=1), 0.0, 60, None, None),
            # Bucket 2: p50 missing, p90 present -- the two percentiles are
            # independent per bucket.
            (start + datetime.timedelta(hours=2), 1.0, 60, None, 300.0),
        ]

        cells = status.latency_cells(series, start, width_s, count)

        self.assertEqual(len(cells), 3)
        self.assertAlmostEqual(cells[0]["p50"], 120.0)
        self.assertAlmostEqual(cells[0]["p90"], 230.0)
        self.assertIsNone(cells[1]["p50"])
        self.assertIsNone(cells[1]["p90"])
        self.assertIsNone(cells[2]["p50"])
        self.assertAlmostEqual(cells[2]["p90"], 300.0)

    def test_datapoint_outside_range_is_discarded(self):
        # Same floor-division-then-bounds-check discipline as grid_cells():
        # a point before `start` or past `start + count*width` is dropped,
        # not smeared into cell 0 or the last cell.
        start = dt(2026, 7, 15, 0, 0, 0)
        series = [
            (start - datetime.timedelta(hours=1), 1.0, 60, 999.0, 999.0),
            (start + datetime.timedelta(hours=10), 1.0, 60, 999.0, 999.0),
        ]
        cells = status.latency_cells(series, start, 3600, 3)
        self.assertTrue(all(c["p50"] is None and c["p90"] is None for c in cells))


class LatencyCellsWeightingTests(unittest.TestCase):
    """latency_cells() weights each cell-level average by the period's own
    sample count, so an under-filled period moves a cell less than a full one.
    """

    def test_probe_average_is_weighted_by_sample_count(self):
        # Two periods in one cell: a 200-sample period at 100ms and a
        # 2-sample period at 900ms. An unweighted mean would read 500ms;
        # weighted by count it sits close to the heavy period instead.
        start = dt(2026, 7, 15, 0, 0, 0)
        series = [
            (start, 1.0, 200, 100.0, 100.0),
            (start + datetime.timedelta(minutes=1), 1.0, 2, 900.0, 900.0),
        ]
        cells = status.latency_cells(series, start, 3600, 1)
        self.assertAlmostEqual(cells[0]["p50"], (100.0 * 200 + 900.0 * 2) / 202)

    def test_constant_sample_count_reproduces_the_old_unweighted_mean(self):
        # The probe's steady cadence: every period's count is the same, so
        # weighting is a no-op and this reproduces
        # LatencyCellsTests.test_buckets_average_and_gaps_stay_none's numbers
        # exactly -- the "existing numbers do not move" guarantee for the
        # probe series.
        start = dt(2026, 7, 15, 0, 0, 0)
        series = [
            (start, 1.0, 60, 100.0, 200.0),
            (start + datetime.timedelta(minutes=30), 1.0, 60, 140.0, 260.0),
        ]
        cells = status.latency_cells(series, start, 3600, 1)
        self.assertAlmostEqual(cells[0]["p50"], 120.0)
        self.assertAlmostEqual(cells[0]["p90"], 230.0)


class ReliabilityWindowTests(unittest.TestCase):
    def test_rows_are_ts_avg_samples_p50_p90(self):
        ts = dt(2026, 7, 15, 0, 0, 0)
        seen_ids = []
        values = {"avg": 0.9, "cnt": 1440, "p50": 100.0, "p90": 200.0}

        def fake(MetricDataQueries, StartTime, EndTime, ScanBy):
            seen_ids.extend(q["Id"] for q in MetricDataQueries)
            return {
                "MetricDataResults": [
                    {"Id": q["Id"], "Timestamps": [ts], "Values": [values[q["Id"]]]}
                    for q in MetricDataQueries
                ]
            }

        with mock.patch.object(
            status.cloudwatch, "get_metric_data", side_effect=fake, create=True
        ):
            rows = status.reliability_window(
                ts, ts + datetime.timedelta(seconds=86400), 86400
            )

        self.assertEqual(sorted(seen_ids), ["avg", "cnt", "p50", "p90"])
        self.assertEqual(rows, [(ts, 0.9, 1440, 100.0, 200.0)])


class ReliabilityDecimalsTests(unittest.TestCase):
    """Every range's tile is rounded to the same UPTIME_DECIMALS, shipped
    once at the payload's top level (reliability.decimals) rather than per
    range -- see reliability()'s render-time round(uptime, UPTIME_DECIMALS)
    (weighted_uptime() itself still returns full precision; see
    WeightedUptimeTests for that).
    """

    def test_ranges_decimals_match_the_plan(self):
        self.assertEqual(status.UPTIME_DECIMALS, 3)

    def test_uptime_rounds_to_uptime_decimals_for_every_range(self):
        # A constant avg on every datapoint of every query, regardless of
        # period_s, so every range's weighted_uptime() -- interior buckets,
        # boundary buckets, whatever mix of fractions they land on -- comes
        # out to exactly the same full-precision value before rounding.
        # 1 - 1/1024 is an exact binary fraction, chosen so no float-rounding
        # ambiguity from this fixture's own arithmetic can creep into the
        # comparison below.
        avg = 1 - 1 / 1024.0

        def fake_get_metric_data(MetricDataQueries, StartTime, EndTime, ScanBy):
            period_s = MetricDataQueries[0]["MetricStat"]["Period"]
            period_td = datetime.timedelta(seconds=period_s)
            n = int((EndTime - StartTime).total_seconds() // period_s) + 2
            timestamps = [StartTime + i * period_td for i in range(n)]
            results = []
            for q in MetricDataQueries:
                if q["Id"] == "avg":
                    values = [avg] * n
                elif q["Id"] == "cnt":
                    values = [60] * n
                else:  # p50/p90 -- irrelevant to uptime, kept simple
                    values = [100.0] * n
                results.append(
                    {"Id": q["Id"], "Timestamps": timestamps, "Values": values}
                )
            return {"MetricDataResults": results}

        with (
            mock.patch.object(
                status.cloudwatch,
                "get_metric_data",
                side_effect=fake_get_metric_data,
                create=True,
            ),
            FakeLogs().patch(),
        ):
            result = status.reliability()

        self.assertEqual(result["decimals"], status.UPTIME_DECIMALS)
        expected = round(avg * 100, status.UPTIME_DECIMALS)
        for key in status.RANGES:
            with self.subTest(range=key):
                r = result["ranges"][key]
                self.assertNotIn("decimals", r)
                self.assertEqual(r["uptime"], expected)
                self.assertEqual(r["uptime_excl_planned"], expected)


class HostRootVolumeTests(unittest.TestCase):
    """host()'s root_volume_id -- resolved from RootDeviceName against the
    same describe_instances response's BlockDeviceMappings, at zero extra
    AWS calls, so storage() can label the root volume authoritatively."""

    def _fake_group(self):
        return {
            "AutoScalingGroups": [
                {
                    "DesiredCapacity": 1,
                    "MinSize": 1,
                    "MaxSize": 1,
                    "Instances": [{"InstanceId": "i-main"}],
                }
            ]
        }

    def test_resolves_root_volume_id_from_block_device_mappings(self):
        def fake_describe_instances(InstanceIds):
            return {
                "Reservations": [
                    {
                        "Instances": [
                            {
                                "InstanceType": "t3.small",
                                "Architecture": "x86_64",
                                "Placement": {"AvailabilityZone": "us-east-1a"},
                                "LaunchTime": dt(2026, 8, 1),
                                "ImageId": "ami-main",
                                "RootDeviceName": "/dev/xvda",
                                "BlockDeviceMappings": [
                                    {
                                        "DeviceName": "/dev/xvda",
                                        "Ebs": {"VolumeId": "vol-root"},
                                    },
                                    {
                                        "DeviceName": "/dev/sdf",
                                        "Ebs": {"VolumeId": "vol-test"},
                                    },
                                ],
                            }
                        ]
                    }
                ]
            }

        with (
            mock.patch.object(
                status.autoscaling,
                "describe_auto_scaling_groups",
                return_value=self._fake_group(),
                create=True,
            ),
            mock.patch.object(
                status.ec2,
                "describe_instances",
                side_effect=fake_describe_instances,
                create=True,
            ),
        ):
            result = status.host()

        self.assertEqual(result["instance"]["root_volume_id"], "vol-root")

    def test_no_block_device_mapping_for_root_device_is_none(self):
        def fake_describe_instances(InstanceIds):
            return {
                "Reservations": [
                    {
                        "Instances": [
                            {
                                "InstanceType": "t3.small",
                                "Architecture": "x86_64",
                                "Placement": {"AvailabilityZone": "us-east-1a"},
                                "LaunchTime": dt(2026, 8, 1),
                                "ImageId": "ami-main",
                                "RootDeviceName": "/dev/xvda",
                                "BlockDeviceMappings": [
                                    {
                                        "DeviceName": "/dev/sdf",
                                        "Ebs": {"VolumeId": "vol-test"},
                                    }
                                ],
                            }
                        ]
                    }
                ]
            }

        with (
            mock.patch.object(
                status.autoscaling,
                "describe_auto_scaling_groups",
                return_value=self._fake_group(),
                create=True,
            ),
            mock.patch.object(
                status.ec2,
                "describe_instances",
                side_effect=fake_describe_instances,
                create=True,
            ),
        ):
            result = status.host()

        self.assertIsNone(result["instance"]["root_volume_id"])


class StorageTests(unittest.TestCase):
    """storage(root_volume_id) -- EBS_VOLUME_ID (env, "vol-test") is always
    the data volume; root_volume_id comes from host()'s own describe_
    instances response. Render order is data then root, and a missing or
    unresolvable root id degrades to the data volume alone rather than
    failing the panel."""

    def _fake_volume(self, volume_id, device, size_gb, encrypted):
        return {
            "VolumeId": volume_id,
            "Size": size_gb,
            "VolumeType": "gp3",
            "Iops": 3000,
            "Encrypted": encrypted,
            "State": "in-use",
            "Attachments": [{"Device": device}],
        }

    def test_both_volumes_present_data_then_root(self):
        def fake_describe_volumes(VolumeIds):
            self.assertEqual(set(VolumeIds), {"vol-test", "vol-root"})
            return {
                "Volumes": [
                    self._fake_volume("vol-root", "/dev/xvda", 16, False),
                    self._fake_volume("vol-test", "/dev/sdf", 20, True),
                ]
            }

        with (
            mock.patch.object(
                status.ec2,
                "describe_volumes",
                side_effect=fake_describe_volumes,
                create=True,
            ),
            mock.patch.object(status, "s3_bucket_metrics", return_value=(0, 0)),
        ):
            result = status.storage("vol-root")

        self.assertNotIn("volume_error", result)
        roles = [v["role"] for v in result["volumes"]]
        self.assertEqual(roles, ["data", "root"])
        data, root = result["volumes"]
        self.assertEqual(data["id"], "vol-test")
        self.assertEqual(data["device"], "/dev/sdf")
        self.assertTrue(data["encrypted"])
        self.assertEqual(root["id"], "vol-root")
        self.assertEqual(root["device"], "/dev/xvda")
        self.assertFalse(root["encrypted"])

    def test_missing_root_volume_id_degrades_to_data_alone(self):
        def fake_describe_volumes(VolumeIds):
            self.assertEqual(VolumeIds, ["vol-test"])
            return {"Volumes": [self._fake_volume("vol-test", "/dev/sdf", 20, True)]}

        with (
            mock.patch.object(
                status.ec2,
                "describe_volumes",
                side_effect=fake_describe_volumes,
                create=True,
            ),
            mock.patch.object(status, "s3_bucket_metrics", return_value=(0, 0)),
        ):
            result = status.storage(None)

        self.assertEqual([v["role"] for v in result["volumes"]], ["data"])

    def test_root_volume_id_not_returned_degrades_to_data_alone(self):
        # host()'s root_volume_id is stale (the instance swapped mid-call) --
        # describe_volumes simply omits it rather than erroring.
        def fake_describe_volumes(VolumeIds):
            return {"Volumes": [self._fake_volume("vol-test", "/dev/sdf", 20, True)]}

        with (
            mock.patch.object(
                status.ec2,
                "describe_volumes",
                side_effect=fake_describe_volumes,
                create=True,
            ),
            mock.patch.object(status, "s3_bucket_metrics", return_value=(0, 0)),
        ):
            result = status.storage("vol-gone")

        self.assertEqual([v["role"] for v in result["volumes"]], ["data"])

    def test_describe_volumes_failure_sets_volume_error_not_volumes(self):
        with (
            mock.patch.object(
                status.ec2,
                "describe_volumes",
                side_effect=Exception("Throttling: Rate exceeded"),
                create=True,
            ),
            mock.patch.object(status, "s3_bucket_metrics", return_value=(0, 0)),
        ):
            result = status.storage("vol-root")

        self.assertNotIn("volumes", result)
        self.assertIn("Throttling", result["volume_error"])

    def test_no_ebs_volume_id_reports_root_only_no_data_role(self):
        """EBS_VOLUME_ID empty: describe_volumes is called for the root volume
        alone and no "data" role appears."""

        def fake_describe_volumes(VolumeIds):
            self.assertEqual(VolumeIds, ["vol-root"])
            return {"Volumes": [self._fake_volume("vol-root", "/dev/xvda", 16, False)]}

        with (
            mock.patch.object(status, "EBS_VOLUME_ID", ""),
            mock.patch.object(
                status.ec2,
                "describe_volumes",
                side_effect=fake_describe_volumes,
                create=True,
            ),
            mock.patch.object(status, "s3_bucket_metrics", return_value=(0, 0)),
        ):
            result = status.storage("vol-root")

        self.assertEqual([v["role"] for v in result["volumes"]], ["root"])

    def test_no_ebs_volume_id_and_no_root_id_skips_describe_volumes_call(self):
        with (
            mock.patch.object(status, "EBS_VOLUME_ID", ""),
            mock.patch.object(
                status.ec2, "describe_volumes", create=True
            ) as describe_volumes,
            mock.patch.object(status, "s3_bucket_metrics", return_value=(0, 0)),
        ):
            result = status.storage(None)

        describe_volumes.assert_not_called()
        self.assertEqual(result["volumes"], [])


class CollectStatusIntegrationTests(unittest.TestCase):
    """collect_status() itself had no direct coverage anywhere else in this
    file -- every other test exercises one panel function in isolation.
    Regression test for a real bug (caught only by an actual live Lambda
    invocation, not by any of the per-function tests above): naming the
    popped result `host_image_storage` in collect_status() shadowed the
    `host_image_storage` function referenced earlier in the same function's
    branches list, which Python resolves as a local name for the *whole*
    function body once it's assigned anywhere in it -- an UnboundLocalError
    on every request, not caught by mypy/ruff or any function-scoped test.
    Stubs every leaf panel function (reliability/incidents/host/image/
    storage/deployment) so this runs the real fan-out/safe_section/pop/merge
    control flow end to end, the same flow the bug was in.
    """

    class FakeContext:
        def get_remaining_time_in_millis(self):
            return 10_000

    def test_runs_without_raising_and_merges_host_image_storage(self):
        with (
            mock.patch.object(status, "reliability", return_value={"ranges": {}}),
            mock.patch.object(status, "incidents", return_value=[]),
            mock.patch.object(
                status, "host", return_value={"capacity": {}, "instance": None}
            ),
            mock.patch.object(
                status,
                "image",
                return_value={"error": "no running instance to read an AMI from"},
            ),
            mock.patch.object(
                status,
                "storage",
                return_value={
                    "volumes": [],
                    "bucket_size_bytes": None,
                    "bucket_object_count": None,
                },
            ),
            mock.patch.object(
                status,
                "deployment",
                return_value={"latest": None, "latest_succeeded": None},
            ),
        ):
            result = status.collect_status(self.FakeContext())

        self.assertNotIn("host_image_storage", result)
        self.assertEqual(result["host"], {"capacity": {}, "instance": None})
        self.assertEqual(
            result["image"], {"error": "no running instance to read an AMI from"}
        )
        self.assertEqual(
            result["storage"],
            {"volumes": [], "bucket_size_bytes": None, "bucket_object_count": None},
        )

    def test_host_failure_degrades_image_and_storage_too(self):
        with (
            mock.patch.object(status, "reliability", return_value={"ranges": {}}),
            mock.patch.object(status, "incidents", return_value=[]),
            mock.patch.object(
                status, "host", side_effect=Exception("Throttling: Rate exceeded")
            ),
            mock.patch.object(
                status,
                "deployment",
                return_value={"latest": None, "latest_succeeded": None},
            ),
        ):
            result = status.collect_status(self.FakeContext())

        # host()/image() degrade to the generic {"error": ...} shape; storage()
        # degrades on its own terms (volume_error + null bucket fields, no
        # top-level "error") -- both are real host_image_storage() outcomes,
        # not one uniform contract.
        for key in ("host", "image"):
            with self.subTest(panel=key):
                self.assertIn("error", result[key])
        self.assertIn("volume_error", result["storage"])
        self.assertNotIn("error", result["storage"])


class SeriesResponseTests(unittest.TestCase):
    """GET /_status/series -- driven through handler(), not
    series_response() directly: the CollectStatusIntegrationTests lesson (a
    function-shadowing local invisible to per-function tests) applies to any
    new handler() branch just as much as it did to collect_status()'s own.
    """

    class FakeContext:
        def get_remaining_time_in_millis(self):
            return 10_000

    def setUp(self):
        status._series_cache.clear()
        patcher = mock.patch.object(
            status, "authenticate", return_value=(status.ROLES["owner"], "owner")
        )
        patcher.start()
        self.addCleanup(patcher.stop)

    @staticmethod
    def _event(query):
        return {
            "requestContext": {"http": {"method": "GET"}},
            "rawPath": "/_status/series",
            "headers": {"x-gramps-token": "t"},
            "queryStringParameters": query,
        }

    def _call(self, query):
        return status.handler(self._event(query), self.FakeContext())

    def test_unauthenticated_is_401(self):
        with mock.patch.object(status, "authenticate", return_value=(None, None)):
            resp = self._call(
                {"panel": "reliability", "range": "24h", "end": "2026-01-01T00:00:00Z"}
            )
        self.assertEqual(resp["statusCode"], 401)

    def test_below_min_role_is_403(self):
        with mock.patch.object(
            status, "authenticate", return_value=(status.ROLES["guest"], "guest")
        ):
            resp = self._call(
                {"panel": "reliability", "range": "24h", "end": "2026-01-01T00:00:00Z"}
            )
        self.assertEqual(resp["statusCode"], 403)

    def test_missing_panel_is_400(self):
        resp = self._call({"range": "24h", "end": "2026-01-01T00:00:00Z"})
        self.assertEqual(resp["statusCode"], 400)

    def test_unknown_panel_is_400(self):
        resp = self._call(
            {"panel": "incidents", "range": "24h", "end": "2026-01-01T00:00:00Z"}
        )
        self.assertEqual(resp["statusCode"], 400)

    def test_disabled_panel_toggle_is_404(self):
        # HOST_METRICS_ENABLED/LLM_ENABLED both default to "false" in this
        # test environment (see the module docstring at the top of this
        # file) -- reliability has no such toggle, so it's excluded here.
        for panel in ("host_metrics", "assistant"):
            with self.subTest(panel=panel):
                resp = self._call(
                    {"panel": panel, "range": "24h", "end": "2026-01-01T00:00:00Z"}
                )
                self.assertEqual(resp["statusCode"], 404)

    def test_missing_range_is_400(self):
        resp = self._call({"panel": "reliability", "end": "2026-01-01T00:00:00Z"})
        self.assertEqual(resp["statusCode"], 400)

    def test_unknown_range_is_400(self):
        resp = self._call(
            {"panel": "reliability", "range": "2y", "end": "2026-01-01T00:00:00Z"}
        )
        self.assertEqual(resp["statusCode"], 400)

    def test_missing_end_is_400(self):
        resp = self._call({"panel": "reliability", "range": "24h"})
        self.assertEqual(resp["statusCode"], 400)

    def test_unparseable_end_is_400(self):
        resp = self._call({"panel": "reliability", "range": "24h", "end": "not-a-date"})
        self.assertEqual(resp["statusCode"], 400)

    def test_future_end_is_400(self):
        future = status.iso(datetime.datetime.now(UTC) + datetime.timedelta(days=1))
        resp = self._call({"panel": "reliability", "range": "24h", "end": future})
        self.assertEqual(resp["statusCode"], 400)

    def test_end_comfortably_within_clamp_is_allowed(self):
        end = status.iso(datetime.datetime.now(UTC) - datetime.timedelta(days=450))
        with mock.patch.object(
            status, "reliability", return_value={"ranges": {"24h": {"cells": []}}}
        ):
            resp = self._call({"panel": "reliability", "range": "24h", "end": end})
        self.assertEqual(resp["statusCode"], 200)

    def test_end_comfortably_past_clamp_is_400(self):
        end = status.iso(
            datetime.datetime.now(UTC)
            - datetime.timedelta(days=status.SERIES_MAX_AGE_DAYS + 1)
        )
        resp = self._call({"panel": "reliability", "range": "24h", "end": end})
        self.assertEqual(resp["statusCode"], 400)

    def test_valid_request_returns_one_range_key_and_threads_keys_through(self):
        end = status.iso(datetime.datetime.now(UTC) - datetime.timedelta(days=5))
        with mock.patch.object(
            status, "reliability", return_value={"ranges": {"24h": {"cells": []}}}
        ) as mock_rel:
            resp = self._call({"panel": "reliability", "range": "24h", "end": end})

        self.assertEqual(resp["statusCode"], 200)
        body = json.loads(resp["body"])
        self.assertEqual(body["panel"], "reliability")
        self.assertEqual(body["range"], "24h")
        self.assertEqual(body["end"], end)
        self.assertEqual(set(body["data"]["ranges"]), {"24h"})
        # safe_section(f"series:{panel_name}", fn, end, [range_key]) calls
        # fn(end, [range_key]) positionally -- confirm both arrive, not just
        # that *a* call happened.
        args, _kwargs = mock_rel.call_args
        self.assertEqual(status.iso(args[0]), end)
        self.assertEqual(args[1], ["24h"])

    def test_lru_hit_skips_a_second_call(self):
        end = status.iso(datetime.datetime.now(UTC) - datetime.timedelta(days=5))
        with mock.patch.object(
            status, "reliability", return_value={"ranges": {"24h": {"cells": []}}}
        ) as mock_rel:
            self._call({"panel": "reliability", "range": "24h", "end": end})
            self._call({"panel": "reliability", "range": "24h", "end": end})
        self.assertEqual(mock_rel.call_count, 1)

    def test_degraded_result_is_never_cached(self):
        end = status.iso(datetime.datetime.now(UTC) - datetime.timedelta(days=5))
        with mock.patch.object(
            status, "reliability", return_value={"error": "boom"}
        ) as mock_rel:
            self._call({"panel": "reliability", "range": "24h", "end": end})
            self._call({"panel": "reliability", "range": "24h", "end": end})
        self.assertEqual(mock_rel.call_count, 2)


class ReliabilityNowKeysTests(unittest.TestCase):
    """reliability(now=X, keys=[...]) -- /_status/series' own hooks (see
    that function's docstring): keys narrows both the ranges shipped and
    excl_windows' own lookback, and now shifts the newest cell to land near
    X rather than today.
    """

    @staticmethod
    def _fake_get_metric_data(MetricDataQueries, StartTime, EndTime, ScanBy):
        period_s = MetricDataQueries[0]["MetricStat"]["Period"]
        period_td = datetime.timedelta(seconds=period_s)
        n = int((EndTime - StartTime).total_seconds() // period_s) + 2
        timestamps = [StartTime + i * period_td for i in range(n)]
        values_by_id = {
            "avg": [1.0] * n,
            "cnt": [60] * n,
            "p50": [100.0] * n,
            "p90": [200.0] * n,
        }
        return {
            "MetricDataResults": [
                {
                    "Id": q["Id"],
                    "Timestamps": timestamps,
                    "Values": values_by_id[q["Id"]],
                }
                for q in MetricDataQueries
            ]
        }

    def test_keys_narrows_ranges_and_now_shifts_the_newest_cell(self):
        x = dt(2020, 1, 15, 12, 0, 0)

        with (
            mock.patch.object(status, "planned_windows", return_value=[]),
            mock.patch.object(
                status.cloudwatch,
                "get_metric_data",
                side_effect=self._fake_get_metric_data,
                create=True,
            ),
        ):
            result = status.reliability(now=x, keys=["24h"])

        self.assertEqual(set(result["ranges"]), {"24h"})
        cells = result["ranges"]["24h"]["cells"]
        self.assertTrue(cells)
        self.assertIn("2020-01-15", cells[-1]["label"])

    def test_keys_narrows_the_exclusion_lookback(self):
        x = dt(2020, 1, 15, 12, 0, 0)

        with (
            mock.patch.object(
                status, "planned_windows", return_value=[]
            ) as mock_planned,
            mock.patch.object(
                status.cloudwatch,
                "get_metric_data",
                side_effect=self._fake_get_metric_data,
                create=True,
            ),
        ):
            status.reliability(now=x, keys=["24h"])

        # RANGES["24h"]["window_days"] == 1 -- not the flat
        # INCIDENTS_LOOKBACK_DAYS (365) a live, all-five-ranges call uses.
        mock_planned.assert_called_once_with(days=1, now=x, episode_log=None)


class ImageSourceAmiFallbackTests(unittest.TestCase):
    """image(ami_id) -- the source AMI description lookup is best-effort;
    Amazon deregistering an old AL2023 source AMI must degrade to the
    build-time source_ami_name tag, not fail the whole panel.
    """

    def test_falls_back_to_source_ami_name_when_source_ami_not_found(self):
        def fake_describe_images(ImageIds):
            if ImageIds == ["ami-main"]:
                return {
                    "Images": [
                        {
                            "Name": "gramps-web-2026-08-09",
                            "CreationDate": "2026-08-09T00:00:00.000Z",
                            "Tags": [
                                {"Key": "git_sha", "Value": "abc123def456"},
                                {"Key": "source_ami", "Value": "ami-deregistered"},
                                {
                                    "Key": "source_ami_name",
                                    "Value": "al2023-ami-2026.07.20",
                                },
                            ],
                        }
                    ]
                }
            if ImageIds == ["ami-deregistered"]:
                raise Exception(
                    "InvalidAMIID.NotFound: The image id '[ami-deregistered]' does not exist"
                )
            raise AssertionError(f"unexpected ImageIds: {ImageIds}")

        with mock.patch.object(
            status.ec2, "describe_images", side_effect=fake_describe_images, create=True
        ):
            result = status.image("ami-main")

        self.assertNotIn("error", result)
        self.assertEqual(result["id"], "ami-main")
        self.assertEqual(result["source_ami"], "ami-deregistered")
        self.assertEqual(result["source_ami_name"], "al2023-ami-2026.07.20")
        self.assertIsNone(result["source_ami_description"])

    def test_populates_description_when_source_ami_is_found(self):
        def fake_describe_images(ImageIds):
            if ImageIds == ["ami-main"]:
                return {
                    "Images": [
                        {
                            "Name": "n",
                            "CreationDate": "2026-08-09T00:00:00.000Z",
                            "Tags": [
                                {"Key": "source_ami", "Value": "ami-source"},
                                {
                                    "Key": "source_ami_name",
                                    "Value": "al2023-ami-2026.07.20",
                                },
                            ],
                        }
                    ]
                }
            if ImageIds == ["ami-source"]:
                return {
                    "Images": [
                        {
                            "Description": "Amazon Linux 2023 AMI 2023.12.20260803.3 x86_64 HVM kernel-6.1"
                        }
                    ]
                }
            raise AssertionError(f"unexpected ImageIds: {ImageIds}")

        with mock.patch.object(
            status.ec2, "describe_images", side_effect=fake_describe_images, create=True
        ):
            result = status.image("ami-main")

        self.assertEqual(
            result["source_ami_description"],
            "Amazon Linux 2023 AMI 2023.12.20260803.3 x86_64 HVM kernel-6.1",
        )


def _period_of(queries):
    """The Period every MetricDataQueries entry in one call shares -- both
    host_metrics() and assistant() issue one call per distinct period_s, all
    metrics/series together, so any query in the list names it."""
    return queries[0]["MetricStat"]["Period"]


def _max_cells_for_period(period_s):
    """The cell count host_metrics()/assistant() actually fetch for a given
    period_s: the longest CHART_RANGES entry sharing it, since 30d/90d/1y
    collapse into one call sized to 1y's 365 cells."""
    return max(
        spec["cells"]
        for spec in status.CHART_RANGES.values()
        if spec["period_s"] == period_s
    )


class HostMetricsShapeTests(unittest.TestCase):
    """host_metrics() -- up to three GetMetricData calls (deduplicated by
    period_s; see HostMetricsDedupTests below), three series, each shaped
    {"current": <float or None>, "ranges": {"24h": [...], "7d": [...], ...}}.
    """

    def test_shape_and_current_value(self):
        # Timestamps are derived from the StartTime the fake is actually
        # handed, one per period across the whole fetched window -- not a
        # single point near the start, which would land inside 1y's window
        # (the longest range sharing period_s=86400) but miss 30d/90d's own,
        # more recent sub-window of that same shared call. All values are
        # identical so "current" (read off period_s=1800's own newest
        # datapoint) is unambiguous regardless of which timestamp CloudWatch
        # happens to report as newest.
        def fake_get_metric_data(MetricDataQueries, StartTime, EndTime, ScanBy):
            ids = [q["Id"] for q in MetricDataQueries]
            self.assertEqual(
                set(ids), {"cpu_percent", "mem_used_percent", "disk_used_percent"}
            )
            period_s = _period_of(MetricDataQueries)
            period_td = datetime.timedelta(seconds=period_s)
            n = _max_cells_for_period(period_s) + 1
            timestamps = [StartTime + i * period_td for i in range(n)]
            values = [42.345] * n
            return {
                "MetricDataResults": [
                    {"Id": qid, "Timestamps": timestamps, "Values": values}
                    for qid in ids
                ]
            }

        with mock.patch.object(
            status.cloudwatch,
            "get_metric_data",
            side_effect=fake_get_metric_data,
            create=True,
        ):
            result = status.host_metrics()

        for key in ("cpu_percent", "mem_used_percent", "disk_used_percent"):
            self.assertIn(key, result)
            self.assertEqual(result[key]["current"], 42.3)
            for range_key, spec in status.CHART_RANGES.items():
                with self.subTest(metric=key, range=range_key):
                    series = result[key]["ranges"][range_key]
                    self.assertEqual(len(series), spec["cells"])
                    self.assertTrue(
                        all(v is None or isinstance(v, float) for v in series)
                    )
                    # The old assertion above is satisfied by an all-None
                    # series too -- this is the one that actually catches a
                    # broken join.
                    self.assertTrue(
                        any(v is not None for v in series),
                        f"{key}'s {range_key} series is all-None",
                    )

    def test_series_populates_at_unaligned_wall_clock_time(self):
        # bucket_series() joins CloudWatch's response back against a bucket
        # grid derived from an unaligned StartTime (now - 24h, only
        # minute-rounded) using floor division, not exact epoch-aligned
        # timestamp equality: an exact-equality join would miss every
        # returned timestamp -- and collapse the whole series to None --
        # unless the Lambda happened to run at :00 or :30. Freezing "now" at
        # a deliberately period-unaligned instant (:07:23) and having the
        # fake CloudWatch response come back anchored to the StartTime
        # actually passed (as real CloudWatch does) reproduces exactly that
        # scenario, so this test fails against an exact-equality join and
        # passes against floor division. Ported to the 24h range only -- the
        # join lives in bucket_series(), shared unchanged by every range, so
        # one range is sufficient to catch a regression here.
        fixed_now = dt(2026, 7, 15, 13, 7, 23)

        class FrozenDatetime(datetime.datetime):
            @classmethod
            def now(cls, tz=None):
                return fixed_now if tz is None else fixed_now.astimezone(tz)

        def fake_get_metric_data(MetricDataQueries, StartTime, EndTime, ScanBy):
            ids = [q["Id"] for q in MetricDataQueries]
            period_s = _period_of(MetricDataQueries)
            period_td = datetime.timedelta(seconds=period_s)
            # A real CloudWatch response: timestamps anchored to the
            # StartTime actually passed, one per period -- including the
            # just-started current period, which by design falls at or
            # before EndTime -- never derived from wall-clock "now".
            n = _max_cells_for_period(period_s) + 1
            timestamps = [StartTime + i * period_td for i in range(n)]
            values = [10.0 + i for i in range(n)]
            return {
                "MetricDataResults": [
                    {"Id": qid, "Timestamps": timestamps, "Values": values}
                    for qid in ids
                ]
            }

        with (
            mock.patch.object(status.datetime, "datetime", FrozenDatetime),
            mock.patch.object(
                status.cloudwatch,
                "get_metric_data",
                side_effect=fake_get_metric_data,
                create=True,
            ),
        ):
            result = status.host_metrics()

        for key in ("cpu_percent", "mem_used_percent", "disk_used_percent"):
            self.assertIn(key, result)
            series = result[key]["ranges"]["24h"]
            self.assertEqual(len(series), status.CHART_RANGES["24h"]["cells"])
            self.assertTrue(
                any(v is not None for v in series),
                f"{key}'s series is all-None at an unaligned now",
            )
            # The bucket closest to "now" should be populated too, not just
            # some earlier one -- the chart's whole point is a current trend.
            self.assertIsNotNone(
                series[-1], f"{key}'s newest bucket is None at an unaligned now"
            )

    def test_missing_metric_in_response_isolates_to_that_key(self):
        # A malformed/partial response (one Id silently absent) degrades
        # only that series, not the whole panel -- the two-call version's
        # per-metric try/except, preserved across the merge into one call
        # per period_s.
        def fake_get_metric_data(MetricDataQueries, StartTime, EndTime, ScanBy):
            return {
                "MetricDataResults": [
                    {"Id": "cpu_percent", "Timestamps": [], "Values": []},
                    {"Id": "mem_used_percent", "Timestamps": [], "Values": []},
                    # disk_used_percent's own result entry is missing entirely.
                ]
            }

        with mock.patch.object(
            status.cloudwatch,
            "get_metric_data",
            side_effect=fake_get_metric_data,
            create=True,
        ):
            result = status.host_metrics()

        self.assertIn("cpu_percent", result)
        self.assertIsNone(result["cpu_percent"]["current"])
        self.assertIn("disk_used_percent_error", result)


class HostMetricsDedupTests(unittest.TestCase):
    """30d/90d/1y all name period_s=86400 in CHART_RANGES, so host_metrics()
    should issue exactly one GetMetricData call for that period_s rather
    than three identical ones -- mirroring RangesCoverageTests' scrutiny of
    the same dedup contract for reliability()'s RANGES table."""

    def test_shares_one_call_for_30d_90d_1y(self):
        periods = []

        def fake_get_metric_data(MetricDataQueries, StartTime, EndTime, ScanBy):
            periods.append(_period_of(MetricDataQueries))
            ids = [q["Id"] for q in MetricDataQueries]
            return {
                "MetricDataResults": [
                    {"Id": qid, "Timestamps": [], "Values": []} for qid in ids
                ]
            }

        with mock.patch.object(
            status.cloudwatch,
            "get_metric_data",
            side_effect=fake_get_metric_data,
            create=True,
        ):
            status.host_metrics()

        distinct_periods = {spec["period_s"] for spec in status.CHART_RANGES.values()}
        self.assertEqual(
            len(periods),
            len(distinct_periods),
            f"expected one call per distinct period_s, got: {periods}",
        )
        self.assertEqual(
            periods.count(86400), 1, "30d/90d/1y should share a single call"
        )


class HostMetricsVolumeByteArmTests(unittest.TestCase):
    """host_metrics()'s loop, dedup, and per-metric error isolation are
    generic over HOST_METRIC_SPECS -- this exercises them against the
    VOLUME_METRICS_ENABLED="true" arm (four Mount-dimensioned byte series in
    place of disk_used_percent), patched directly onto HOST_METRIC_SPECS
    since it's built once at import time from an env var this test process
    already imported status.py without."""

    BYTE_SPECS = (
        (
            "cpu_percent",
            "AWS/EC2",
            "CPUUtilization",
            [{"Name": "AutoScalingGroupName", "Value": "test-asg"}],
        ),
        ("mem_used_percent", "test/SiteUp", "MemUsedPercent", []),
        (
            "disk_used_bytes_data",
            "test/SiteUp",
            "DiskUsedBytes",
            [{"Name": "Mount", "Value": "data"}],
        ),
        (
            "disk_total_bytes_data",
            "test/SiteUp",
            "DiskTotalBytes",
            [{"Name": "Mount", "Value": "data"}],
        ),
        (
            "disk_used_bytes_root",
            "test/SiteUp",
            "DiskUsedBytes",
            [{"Name": "Mount", "Value": "root"}],
        ),
        (
            "disk_total_bytes_root",
            "test/SiteUp",
            "DiskTotalBytes",
            [{"Name": "Mount", "Value": "root"}],
        ),
    )

    def test_all_six_series_shaped_and_populated(self):
        def fake_get_metric_data(MetricDataQueries, StartTime, EndTime, ScanBy):
            ids = [q["Id"] for q in MetricDataQueries]
            self.assertEqual(set(ids), {k for k, *_ in self.BYTE_SPECS})
            period_s = _period_of(MetricDataQueries)
            period_td = datetime.timedelta(seconds=period_s)
            n = _max_cells_for_period(period_s) + 1
            timestamps = [StartTime + i * period_td for i in range(n)]
            values = [1_234_567.0] * n
            return {
                "MetricDataResults": [
                    {"Id": qid, "Timestamps": timestamps, "Values": values}
                    for qid in ids
                ]
            }

        with (
            mock.patch.object(status, "HOST_METRIC_SPECS", self.BYTE_SPECS),
            mock.patch.object(
                status.cloudwatch,
                "get_metric_data",
                side_effect=fake_get_metric_data,
                create=True,
            ),
        ):
            result = status.host_metrics()

        for key in (
            "disk_used_bytes_data",
            "disk_total_bytes_data",
            "disk_used_bytes_root",
            "disk_total_bytes_root",
        ):
            self.assertIn(key, result)
            self.assertEqual(result[key]["current"], 1234567.0)
        self.assertNotIn("disk_used_percent", result)

    def test_one_byte_series_missing_from_response_isolates_to_that_key(self):
        def fake_get_metric_data(MetricDataQueries, StartTime, EndTime, ScanBy):
            ids = [q["Id"] for q in MetricDataQueries]
            return {
                "MetricDataResults": [
                    {"Id": qid, "Timestamps": [], "Values": []}
                    for qid in ids
                    if qid != "disk_total_bytes_root"
                ]
            }

        with (
            mock.patch.object(status, "HOST_METRIC_SPECS", self.BYTE_SPECS),
            mock.patch.object(
                status.cloudwatch,
                "get_metric_data",
                side_effect=fake_get_metric_data,
                create=True,
            ),
        ):
            result = status.host_metrics()

        self.assertIn("disk_used_bytes_data", result)
        self.assertIn("disk_total_bytes_root_error", result)


class AssistantShapeTests(unittest.TestCase):
    """assistant() -- per-CHART_RANGES Bedrock token series and four
    passthrough config fields. No existing coverage before this (there was
    no llm_cloudwatch-backed test in this file at all); llm_cloudwatch is
    patched as a whole module attribute rather than with
    mock.patch.object(status.llm_cloudwatch, ..., create=True) the way
    status.cloudwatch is elsewhere, since llm_cloudwatch is None at import
    time in this test environment (LLM_ENABLED defaults to "false"; see the
    module-level client construction in status.py) and has no attribute
    namespace to patch onto.
    """

    def test_range_series_shape_and_zero_fill(self):
        def fake_get_metric_data(MetricDataQueries, StartTime, EndTime, ScanBy):
            ids = [q["Id"] for q in MetricDataQueries]
            self.assertEqual(set(ids), {"input", "output"})
            period_s = _period_of(MetricDataQueries)
            period_td = datetime.timedelta(seconds=period_s)
            n = _max_cells_for_period(period_s)
            # Timestamps anchored to the StartTime actually passed, one per
            # period across the window -- what a real CloudWatch response
            # looks like, same idiom as the host_metrics regression test
            # above.
            timestamps = [StartTime + i * period_td for i in range(n)]
            values_by_id = {
                "input": [100.0 + i for i in range(n)],
                "output": [50.0 + i for i in range(n)],
            }
            return {
                "MetricDataResults": [
                    {"Id": qid, "Timestamps": timestamps, "Values": values_by_id[qid]}
                    for qid in ids
                ]
            }

        fake_llm_cloudwatch = mock.Mock(
            get_metric_data=mock.Mock(side_effect=fake_get_metric_data)
        )
        with (
            mock.patch.object(status, "llm_cloudwatch", fake_llm_cloudwatch),
            mock.patch.object(status, "LLM_MODEL_ID", "test-model"),
            mock.patch.object(status, "LLM_REGION", "us-west-2"),
            mock.patch.object(status, "LLM_MAX_REQUESTS", "15"),
            mock.patch.object(status, "LLM_MAX_TOKENS", "200000"),
            mock.patch.object(status, "LLM_MAX_CONTEXT_LENGTH", "50000"),
        ):
            result = status.assistant()

        for range_key, spec in status.CHART_RANGES.items():
            with self.subTest(range=range_key):
                r = result["token_ranges"][range_key]
                self.assertEqual(len(r["input"]), spec["cells"])
                self.assertEqual(len(r["output"]), spec["cells"])
                self.assertTrue(all(isinstance(v, int) for v in r["input"]))
                self.assertTrue(all(isinstance(v, int) for v in r["output"]))
        self.assertEqual(result["model_id"], "test-model")
        self.assertEqual(result["region"], "us-west-2")
        self.assertEqual(result["max_requests"], 15)
        self.assertEqual(result["max_tokens"], 200000)
        self.assertEqual(result["max_context_length"], 50000)

    def test_missing_config_env_vars_degrade_gracefully(self):
        def fake_get_metric_data(MetricDataQueries, StartTime, EndTime, ScanBy):
            ids = [q["Id"] for q in MetricDataQueries]
            return {
                "MetricDataResults": [
                    {"Id": qid, "Timestamps": [], "Values": []} for qid in ids
                ]
            }

        fake_llm_cloudwatch = mock.Mock(
            get_metric_data=mock.Mock(side_effect=fake_get_metric_data)
        )
        with (
            mock.patch.object(status, "llm_cloudwatch", fake_llm_cloudwatch),
            mock.patch.object(status, "LLM_MODEL_ID", ""),
            mock.patch.object(status, "LLM_REGION", ""),
            mock.patch.object(status, "LLM_MAX_REQUESTS", ""),
            mock.patch.object(status, "LLM_MAX_TOKENS", ""),
            mock.patch.object(status, "LLM_MAX_CONTEXT_LENGTH", ""),
        ):
            result = status.assistant()

        # Numeric config absence -> None, the same convention backups() uses
        # for BACKUP_RETENTION_DAYS et al (int(X) if X else None) -- not a
        # raw empty string and not a fabricated 0.
        self.assertIsNone(result["max_requests"])
        self.assertIsNone(result["max_tokens"])
        self.assertIsNone(result["max_context_length"])
        # String config absence -> "", the same convention model_id/region/
        # GRAMPS_WEB_VERSION already use -- the frontend's Kv component
        # renders "" the same as null/undefined (a dash), so the client
        # needs no special case for this.
        self.assertEqual(result["model_id"], "")
        self.assertEqual(result["region"], "")
        # Zero-fill, not None, in every range: a missing Sum datapoint on a
        # token counter means zero invocations for that period (see
        # assistant()'s comment).
        for range_key, spec in status.CHART_RANGES.items():
            with self.subTest(range=range_key):
                r = result["token_ranges"][range_key]
                self.assertEqual(len(r["input"]), spec["cells"])
                self.assertEqual(len(r["output"]), spec["cells"])
                self.assertTrue(all(v == 0 for v in r["input"]))
                self.assertTrue(all(v == 0 for v in r["output"]))


class AssistantDedupTests(unittest.TestCase):
    """Same dedup contract as HostMetricsDedupTests, for assistant()'s own
    query_cache closure."""

    def test_shares_one_call_for_30d_90d_1y(self):
        periods = []

        def fake_get_metric_data(MetricDataQueries, StartTime, EndTime, ScanBy):
            periods.append(_period_of(MetricDataQueries))
            ids = [q["Id"] for q in MetricDataQueries]
            return {
                "MetricDataResults": [
                    {"Id": qid, "Timestamps": [], "Values": []} for qid in ids
                ]
            }

        fake_llm_cloudwatch = mock.Mock(
            get_metric_data=mock.Mock(side_effect=fake_get_metric_data)
        )
        with mock.patch.object(status, "llm_cloudwatch", fake_llm_cloudwatch):
            status.assistant()

        distinct_periods = {spec["period_s"] for spec in status.CHART_RANGES.values()}
        self.assertEqual(
            len(periods),
            len(distinct_periods),
            f"expected one call per distinct period_s, got: {periods}",
        )
        self.assertEqual(
            periods.count(86400), 1, "30d/90d/1y should share a single call"
        )


class S3BucketMetricsSearchTests(unittest.TestCase):
    """s3_bucket_metrics() -- size now comes from a SUM(SEARCH(...)) metric-
    math expression (summing every StorageType) rather than a hardcoded
    StandardStorage dimension; count is unchanged.
    """

    def test_parses_search_sum_result(self):
        def fake_get_metric_data(MetricDataQueries, StartTime, EndTime, ScanBy):
            size_query = next(q for q in MetricDataQueries if q["Id"] == "size")
            self.assertIn("Expression", size_query)
            self.assertNotIn("MetricStat", size_query)
            self.assertIn("SUM(SEARCH(", size_query["Expression"])
            self.assertIn(
                f'BucketName="{status.MEDIA_BUCKET_NAME}"', size_query["Expression"]
            )
            self.assertIn('MetricName="BucketSizeBytes"', size_query["Expression"])
            self.assertNotIn("StandardStorage", size_query["Expression"])
            return {
                "MetricDataResults": [
                    {
                        "Id": "size",
                        "Values": [130138039.0],
                        "Timestamps": [dt(2026, 8, 9, 0, 0, 0)],
                    },
                    {
                        "Id": "count",
                        "Values": [248.0],
                        "Timestamps": [dt(2026, 8, 9, 0, 0, 0)],
                    },
                ]
            }

        with mock.patch.object(
            status.cloudwatch,
            "get_metric_data",
            side_effect=fake_get_metric_data,
            create=True,
        ):
            size, count = status.s3_bucket_metrics(
                dt(2026, 8, 7, 0, 0, 0), dt(2026, 8, 9, 0, 0, 0)
            )

        self.assertEqual(size, 130138039.0)
        self.assertEqual(count, 248.0)

    def test_call_failure_degrades_to_none_none(self):
        with mock.patch.object(
            status.cloudwatch,
            "get_metric_data",
            side_effect=RuntimeError("boom"),
            create=True,
        ):
            size, count = status.s3_bucket_metrics(
                dt(2026, 8, 7, 0, 0, 0), dt(2026, 8, 9, 0, 0, 0)
            )
        self.assertIsNone(size)
        self.assertIsNone(count)


class EpisodeWindowsTests(unittest.TestCase):
    """episode_windows(days) -- the episode half of planned_windows(): every
    planned=true episode with both started and ended, read via incidents().
    """

    def test_filters_to_planned_episodes_with_started_and_ended(self):
        events = [
            {
                "started": "2026-07-15T10:00:00Z",
                "ended": "2026-07-15T10:04:00Z",
                "duration_s": 240,
                "cause": "deploy",
                "planned": True,
            },
            {
                "started": "2026-07-16T02:00:00Z",
                "ended": "2026-07-16T02:20:00Z",
                "duration_s": 1200,
                "cause": "unknown",
                "planned": False,
            },
        ]
        rows = episode_rows(*enumerate(events))
        with FakeLogs({EPISODES: rows}).patch():
            windows = status.episode_windows(1)
        self.assertEqual(
            windows, [(dt(2026, 7, 15, 10, 0, 0), dt(2026, 7, 15, 10, 4, 0))]
        )

    def test_degrades_to_empty_list_on_failure(self):
        with mock.patch.object(
            status.logs,
            "start_query",
            side_effect=RuntimeError("boom"),
            create=True,
        ):
            self.assertEqual(status.episode_windows(1), [])


class IncidentsPlannedDefaultTests(unittest.TestCase):
    """incidents() reads `planned` from the episode as written: records from
    before the producer emitted it default to unplanned, whatever their cause,
    and a present value is never overridden.
    """

    def test_missing_planned_defaults_to_unplanned(self):
        events = [
            {"started": "2026-07-15T10:00:00Z", "cause": "spot-reclaim"},
            {"started": "2026-07-16T10:00:00Z", "cause": "deploy"},
            {"started": "2026-07-17T10:00:00Z", "cause": "deploy", "planned": True},
            {"started": "2026-07-18T10:00:00Z", "cause": "backup", "planned": True},
        ]
        with FakeLogs({EPISODES: episode_rows(*enumerate(events))}).patch():
            got = {ep["started"][:10]: ep["planned"] for ep in status.incidents(1)}
        self.assertEqual(
            got,
            {
                "2026-07-15": False,
                "2026-07-16": False,
                "2026-07-17": True,
                "2026-07-18": True,
            },
        )


def insights_ts(ms):
    return datetime.datetime.fromtimestamp(ms / 1000, UTC).strftime(
        "%Y-%m-%d %H:%M:%S.%f"
    )[:-3]


class FakeLogs:
    """Logs Insights stand-in. groups: log group -> [(timestamp ms, stream,
    record or raw message)]. statuses: successive get_query_results statuses,
    the last repeating.
    """

    def __init__(self, groups=None, statuses=("Complete",)):
        self.groups = groups or {}
        self.statuses = list(statuses)
        self.started = []

    def start_query(self, **kwargs):
        self.started.append(kwargs)
        return {"queryId": str(len(self.started) - 1)}

    def get_query_results(self, queryId):
        state = self.statuses.pop(0) if len(self.statuses) > 1 else self.statuses[0]
        if state != "Complete":
            return {"status": state, "results": []}
        group = self.started[int(queryId)]["logGroupName"]
        rows = [
            [
                {"field": "@timestamp", "value": insights_ts(ts)},
                {"field": "@logStream", "value": stream},
                {
                    "field": "@message",
                    "value": msg if isinstance(msg, str) else json.dumps(msg),
                },
                {"field": "@ptr", "value": "p"},
            ]
            for ts, stream, msg in self.groups.get(group, [])
        ]
        return {"status": "Complete", "results": rows}

    def reads_of(self, group):
        return sum(1 for q in self.started if q["logGroupName"] == group)

    def patch(self):
        return mock.patch.multiple(
            status.logs,
            create=True,
            start_query=self.start_query,
            get_query_results=self.get_query_results,
        )


EPISODES = "test-log-group"
SPOT = "test-spot-group"


def episode_rows(*records):
    """(log timestamp ms, record) pairs as rows of the episodes stream."""
    return [(ts, status.EPISODES_LOG_STREAM, rec) for ts, rec in records]


def change_rows(*records):
    return [(ts, status.CHANGES_LOG_STREAM, rec) for ts, rec in records]


def episode(started, ended, cause="unknown", **extra):
    return {
        "started": started,
        "ended": ended,
        "duration_s": 60,
        "cause": cause,
        "planned": False,
        **extra,
    }


def change(at, id="d-1", **extra):
    return {
        "at": at,
        "kind": "deploy",
        "id": id,
        "creator": "user",
        "outcome": "succeeded",
        "duration_s": 120,
        "description": None,
        **extra,
    }


NOW = datetime.datetime(2026, 9, 15, 12, 0, 0, tzinfo=datetime.UTC)
NOW_MS = int(NOW.timestamp() * 1000)


class IncidentsDedupeTests(unittest.TestCase):
    """A backfill appends a revised record for an old episode, so one
    `started` can appear twice; the later log event wins, whatever order the
    API returns them in.
    """

    def read(self, *records):
        with FakeLogs({EPISODES: episode_rows(*records)}).patch():
            return status.incidents(365, NOW)

    def test_keeps_the_latest_record_per_started(self):
        original = episode("2026-09-01T10:00:00Z", "2026-09-01T10:05:00Z")
        revised = episode(
            "2026-09-01T10:00:00Z",
            "2026-09-01T10:05:00Z",
            "health-replace",
            revised=True,
        )
        other = episode("2026-09-02T10:00:00Z", "2026-09-02T10:05:00Z", "deploy")
        for order in ([(1, original), (9, revised)], [(9, revised), (1, original)]):
            with self.subTest(order=[ts for ts, _ in order]):
                got = self.read(*order, (5, other))
                self.assertEqual(
                    [(e["started"][:10], e["cause"]) for e in got],
                    [("2026-09-02", "deploy"), ("2026-09-01", "health-replace")],
                )


class IncidentsRobustnessTests(unittest.TestCase):
    def test_records_without_started_stay_separate_and_bare_values_are_skipped(self):
        messages = [
            "7",
            '"x"',
            json.dumps({"cause": "unknown", "duration_s": 1}),
            json.dumps({"cause": "deploy", "duration_s": 2}),
        ]
        rows = episode_rows(*enumerate(messages))
        with FakeLogs({EPISODES: rows}).patch():
            got = status.incidents(365, NOW)
        self.assertEqual(sorted(e["duration_s"] for e in got), [1, 2])


class ChangesTests(unittest.TestCase):
    def read(self, changes, episodes=()):
        rows = change_rows(*changes) + episode_rows(*[(NOW_MS, e) for e in episodes])
        with FakeLogs({EPISODES: rows}).patch():
            return status.changes(365, NOW)

    def test_keeps_the_latest_record_per_id(self):
        got = self.read(
            [
                (1, change("2026-09-01T10:00:00Z", description="first")),
                (2, change("2026-09-01T10:00:00Z", description="second")),
            ]
        )
        self.assertEqual([c["description"] for c in got], ["second"])

    def test_window_uses_the_records_own_at(self):
        got = self.read(
            [
                (NOW_MS, change("2024-01-01T00:00:00Z", id="old")),
                (1, change("2026-09-10T00:00:00Z", id="new")),
            ]
        )
        self.assertEqual([c["id"] for c in got], ["new"])

    def test_newest_first(self):
        got = self.read(
            [
                (1, change("2026-09-01T00:00:00Z", id="a")),
                (2, change("2026-09-03T00:00:00Z", id="b")),
                (3, change("2026-09-02T00:00:00Z", id="c")),
            ]
        )
        self.assertEqual([c["id"] for c in got], ["b", "c", "a"])

    def test_outage_is_derived_from_overlap_with_episodes(self):
        # change spans 09:58:00 - 10:00:00
        at = "2026-09-01T10:00:00Z"
        cases = {
            "inside": ("2026-09-01T09:59:00Z", "2026-09-01T10:03:00Z", True),
            "starts_after_within_slack": (
                "2026-09-01T10:01:00Z",
                "2026-09-01T10:04:00Z",
                True,
            ),
            "starts_after_beyond_slack": (
                "2026-09-01T10:02:00Z",
                "2026-09-01T10:05:00Z",
                False,
            ),
            "ends_before_within_slack": (
                "2026-09-01T09:50:00Z",
                "2026-09-01T09:56:45Z",
                True,
            ),
            "ends_before_beyond_slack": (
                "2026-09-01T09:50:00Z",
                "2026-09-01T09:56:00Z",
                False,
            ),
        }
        for name, (started, ended, expected) in cases.items():
            with self.subTest(name):
                got = self.read([(1, change(at))], [episode(started, ended, "deploy")])
                self.assertIs(got[0]["outage"], expected)

    def test_change_without_duration_overlaps_at_its_instant(self):
        got = self.read(
            [(1, change("2026-09-01T10:00:00Z", duration_s=None))],
            [episode("2026-09-01T10:00:30Z", "2026-09-01T10:03:00Z", "deploy")],
        )
        self.assertTrue(got[0]["outage"])

    def test_only_an_episode_of_the_matching_cause_counts(self):
        spot = episode("2026-09-01T10:01:00Z", "2026-09-01T10:05:00Z", "spot-reclaim")
        refresh = change(
            "2026-09-01T10:30:00Z", kind="instance-refresh", duration_s=1800
        )
        got = self.read([(1, refresh)], [spot])
        self.assertIs(got[0]["outage"], False)
        refreshed = episode(
            "2026-09-01T10:01:00Z", "2026-09-01T10:05:00Z", "instance-refresh"
        )
        got = self.read([(1, refresh)], [refreshed])
        self.assertIs(got[0]["outage"], True)

    def test_a_deploy_episode_overlapping_a_user_deploy_is_an_outage(self):
        got = self.read(
            [(1, change("2026-09-01T10:00:00Z"))],
            [episode("2026-09-01T09:59:00Z", "2026-09-01T10:03:00Z", "deploy")],
        )
        self.assertIs(got[0]["outage"], True)

    def test_autoscaling_deployments_never_report_an_outage(self):
        got = self.read(
            [(1, change("2026-09-01T10:00:00Z", creator="autoscaling"))],
            [episode("2026-09-01T09:59:00Z", "2026-09-01T10:03:00Z", "deploy")],
        )
        self.assertIs(got[0]["outage"], False)

    def test_malformed_lines_are_skipped(self):
        lines = [
            (1, "not json"),
            (2, "123"),
            (3, '"text"'),
            (4, "[1]"),
            (5, json.dumps({"id": "no-at"})),
            (6, json.dumps({"at": "2026-09-01T10:00:00Z"})),
            (7, json.dumps(change("2026-09-01T10:00:00Z"))),
        ]
        with FakeLogs({EPISODES: change_rows(*lines)}).patch():
            got = status.changes(365, NOW)
        self.assertEqual([c["id"] for c in got], ["d-1"])

    def test_no_episodes_means_no_outage(self):
        got = self.read([(1, change("2026-09-01T10:00:00Z"))])
        self.assertIs(got[0]["outage"], False)


class InterruptionsTests(unittest.TestCase):
    def test_malformed_lines_are_skipped(self):
        good = {"time": "t", "detail": {"instance-id": "i-1"}}
        messages = [
            "nope",
            "5",
            '"s"',
            "{}",
            json.dumps({"time": "t"}),
            json.dumps(good),
        ]
        rows = [(n, "s", m) for n, m in enumerate(messages)]
        with FakeLogs({SPOT: rows}).patch():
            got = status.interruptions(365, NOW)
        self.assertEqual(got, [{"time": "t", "instance_id": "i-1", "action": None}])

    def test_reads_warnings_from_the_event_log(self):
        warning = {
            "time": "2026-09-01T10:00:00Z",
            "detail": {"instance-id": "i-1", "instance-action": "terminate"},
        }
        fake = FakeLogs({SPOT: [(1, "s", warning)]})
        with fake.patch():
            got = status.interruptions(365, NOW)
        self.assertEqual(fake.started[0]["logGroupName"], SPOT)
        self.assertEqual(
            got,
            [
                {
                    "time": "2026-09-01T10:00:00Z",
                    "instance_id": "i-1",
                    "action": "terminate",
                }
            ],
        )


class LogReadTests(unittest.TestCase):
    def read(self, fake, deadline=None):
        with fake.patch(), mock.patch.object(status.time, "sleep"):
            return status.LogRead(EPISODES, NOW, 365, deadline).records()

    def test_queries_the_group_over_the_window(self):
        fake = FakeLogs({EPISODES: episode_rows((1, episode("s", "e")))})
        self.read(fake)
        (query,) = fake.started
        self.assertEqual(query["logGroupName"], EPISODES)
        self.assertEqual(query["startTime"], int(NOW.timestamp()) - 365 * 86400)
        self.assertEqual(query["endTime"], int(NOW.timestamp()))
        self.assertEqual(
            query["queryString"],
            "fields @timestamp, @logStream, @message | limit 10000",
        )

    def test_waits_through_scheduled_and_running(self):
        fake = FakeLogs(
            {EPISODES: episode_rows((1, episode("s", "e")))},
            statuses=("Scheduled", "Running", "Complete"),
        )
        self.assertEqual(len(self.read(fake)), 1)

    def test_a_result_count_at_the_limit_raises(self):
        rows = episode_rows(*[(n, {"n": n}) for n in range(status.INSIGHTS_ROW_LIMIT)])
        with self.assertRaisesRegex(RuntimeError, "limit"):
            self.read(FakeLogs({EPISODES: rows}))

    def test_a_result_count_under_the_limit_is_kept_whole(self):
        count = status.INSIGHTS_ROW_LIMIT - 1
        rows = episode_rows(*[(n, {"n": n}) for n in range(count)])
        self.assertEqual(len(self.read(FakeLogs({EPISODES: rows}))), count)

    def test_failed_cancelled_and_timeout_raise(self):
        for state in ("Failed", "Cancelled", "Timeout"):
            with self.subTest(state), self.assertRaisesRegex(RuntimeError, state):
                self.read(FakeLogs(statuses=("Running", state)))

    def test_gives_up_at_the_deadline_instead_of_hanging(self):
        fake = FakeLogs(statuses=("Running",))
        with self.assertRaises(TimeoutError):
            self.read(fake, deadline=status.time.monotonic() - 1)

    def test_splits_by_stream_and_keeps_log_timestamps(self):
        rows = [(5, "a", {"k": 1}), (7, "b", {"k": 2})]
        with FakeLogs({EPISODES: rows}).patch():
            read = status.LogRead(EPISODES, NOW, 365)
            self.assertEqual(read.records("a"), [(5, {"k": 1})])
            self.assertEqual(read.records("b"), [(7, {"k": 2})])
            self.assertEqual(len(read.records()), 2)

    def test_a_failed_read_is_attempted_once(self):
        fake = FakeLogs(statuses=("Failed",))
        with fake.patch():
            read = status.LogRead(EPISODES, NOW, 365)
            for _ in range(2):
                with self.assertRaises(RuntimeError):
                    read.records()
        self.assertEqual(len(fake.started), 1)


class LogGroupReadsPerRequestTests(unittest.TestCase):
    """However many sections draw on a log group, one request queries it once."""

    class FakeContext:
        def get_remaining_time_in_millis(self):
            return 10_000

    def setUp(self):
        status._public_cache.update(data=None, fetched_at=0.0)
        self.addCleanup(status._public_cache.update, data=None, fetched_at=0.0)
        started = "2026-09-01T10:00:00Z"
        self.fake = FakeLogs(
            {
                EPISODES: episode_rows((1, episode(started, started, "deploy")))
                + change_rows((2, change(started))),
                SPOT: [(3, "s", {"time": started, "detail": {"instance-id": "i-1"}})],
            }
        )
        for p in (
            self.fake.patch(),
            mock.patch.object(
                status.cloudwatch,
                "get_metric_data",
                side_effect=ReliabilityNowKeysTests._fake_get_metric_data,
                create=True,
            ),
            mock.patch.object(status, "codedeploy_windows", return_value=[]),
            mock.patch.object(
                status,
                "host_image_storage",
                return_value={"host": 1, "image": 2, "storage": 3},
            ),
            mock.patch.object(status, "deployment", return_value={}),
            mock.patch.object(status, "PUBLIC_RELIABILITY", "true"),
        ):
            p.start()
            self.addCleanup(p.stop)

    def assert_one_read_per_group(self):
        self.assertEqual(self.fake.reads_of(EPISODES), 1)
        self.assertEqual(self.fake.reads_of(SPOT), 1)

    def test_collect_status(self):
        result = status.collect_status(self.FakeContext())
        for name in ("reliability", "incidents", "changes", "interruptions"):
            self.assertNotIn("error", result[name], name)
        self.assertEqual(len(result["incidents"]), 1)
        self.assertEqual(len(result["changes"]), 1)
        self.assertEqual(len(result["interruptions"]), 1)
        self.assert_one_read_per_group()

    def test_public_response(self):
        response = status.public_response(self.FakeContext())
        body = json.loads(response["body"])
        self.assertEqual(len(body["incidents"]), 1)
        self.assert_one_read_per_group()


class PublicResponseTests(unittest.TestCase):
    class FakeContext:
        def get_remaining_time_in_millis(self):
            return 10_000

    def setUp(self):
        status._public_cache.update(data=None, fetched_at=0.0)
        self.addCleanup(status._public_cache.update, data=None, fetched_at=0.0)
        patches = [
            mock.patch.object(status, "PUBLIC_RELIABILITY", "true"),
            mock.patch.object(status, "reliability", return_value={"ranges": {}}),
            mock.patch.object(
                status,
                "incidents",
                return_value=[
                    {**episode("s", "e", "deploy"), "old_instance": {"id": "i-1"}}
                ],
            ),
            mock.patch.object(
                status,
                "changes",
                return_value=[
                    {
                        **change("2026-09-01T10:00:00Z"),
                        "outage": True,
                        "description": "x",
                    }
                ],
            ),
            mock.patch.object(
                status,
                "interruptions",
                return_value=[
                    {"time": "t", "instance_id": "i-1", "action": "terminate"}
                ],
            ),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def get(self):
        response = status.public_response(self.FakeContext())
        return response, json.loads(response["body"])

    def test_changes_and_interruptions_are_trimmed(self):
        _, body = self.get()
        self.assertEqual(
            body["changes"],
            [
                {
                    "at": "2026-09-01T10:00:00Z",
                    "kind": "deploy",
                    "creator": "user",
                    "outcome": "succeeded",
                }
            ],
        )
        self.assertEqual(body["interruptions"], [{"time": "t"}])
        self.assertNotIn("old_instance", body["incidents"][0])

    def test_spot_enabled_flag_follows_the_env_var(self):
        for env, expected in (("true", True), ("false", False)):
            with self.subTest(env=env):
                status._public_cache.update(data=None, fetched_at=0.0)
                with mock.patch.object(status, "SPOT_ENABLED", env):
                    _, body = self.get()
                self.assertIs(body["spot_enabled"], expected)

    def test_public_changes_list_only_deliberate_entries(self):
        changes = [
            {
                **change("2026-09-01T10:00:00Z", id="a", creator="autoscaling"),
                "outage": False,
            },
            {**change("2026-09-02T10:00:00Z", id="b", creator="user"), "outage": False},
            {
                **change(
                    "2026-09-03T10:00:00Z",
                    id="c",
                    kind="instance-refresh",
                    creator=None,
                ),
                "outage": False,
            },
        ]
        with mock.patch.object(status, "changes", return_value=changes):
            _, body = self.get()
        self.assertEqual(
            [c["at"][:10] for c in body["changes"]], ["2026-09-02", "2026-09-03"]
        )

    def test_a_failed_section_degrades_alone_and_is_not_cached(self):
        with mock.patch.object(status, "changes", side_effect=Exception("denied")):
            response, body = self.get()
        self.assertEqual(body["changes"], {"error": "unavailable"})
        self.assertEqual(body["interruptions"], [{"time": "t"}])
        self.assertEqual(
            response["headers"]["Cache-Control"], status.PUBLIC_CACHE_CONTROL_DEGRADED
        )
        self.assertIsNone(status._public_cache["data"])


class DataResponseSpotFlagTests(unittest.TestCase):
    class FakeContext:
        def get_remaining_time_in_millis(self):
            return 10_000

    def test_spot_enabled_flag_follows_the_env_var(self):
        for env, expected in (("true", True), ("false", False)):
            with self.subTest(env=env):
                with (
                    mock.patch.object(status, "SPOT_ENABLED", env),
                    mock.patch.object(
                        status,
                        "require_role",
                        return_value=((status.ROLES["owner"], "owner"), None),
                    ),
                    mock.patch.object(status, "collect_status", return_value={}),
                    mock.patch.dict(status._data_cache, {"data": None}),
                ):
                    response = status.data_response({}, self.FakeContext())
                self.assertIs(json.loads(response["body"])["spot_enabled"], expected)


class CollectStatusChangeSectionsTests(unittest.TestCase):
    class FakeContext:
        def get_remaining_time_in_millis(self):
            return 10_000

    def test_sections_are_present_and_degrade_independently(self):
        with (
            mock.patch.object(status, "reliability", return_value={"ranges": {}}),
            mock.patch.object(status, "incidents", return_value=[]),
            mock.patch.object(status, "changes", side_effect=Exception("denied")),
            mock.patch.object(status, "interruptions", return_value=[]),
            mock.patch.object(
                status,
                "host_image_storage",
                return_value={"host": 1, "image": 2, "storage": 3},
            ),
            mock.patch.object(status, "deployment", return_value={}),
        ):
            result = status.collect_status(self.FakeContext())
        self.assertIn("error", result["changes"])
        self.assertEqual(result["interruptions"], [])
        self.assertEqual(result["incidents"], [])


class CodedeployWindowsTests(unittest.TestCase):
    """codedeploy_windows(days) -- every CodeDeploy deployment's own
    (createTime, completeTime) window, independent of whether it produced an
    episode. A separate paginated read from deployment()'s, since a year
    holds far more deployments than the 25 that inspects.
    """

    def test_paginates_list_deployments_and_chunks_batch_get(self):
        # 30 ids: two list_deployments pages, and two batch_get_deployments
        # calls (25 + 5) since batch_get_deployments caps at 25 per call.
        page1 = [f"d-{i}" for i in range(25)]
        page2 = [f"d-{i}" for i in range(25, 30)]

        def fake_list_deployments(**kwargs):
            if "nextToken" not in kwargs:
                return {"deployments": page1, "nextToken": "tok"}
            self.assertEqual(kwargs["nextToken"], "tok")
            return {"deployments": page2}

        batch_calls = []

        def fake_batch_get_deployments(deploymentIds):
            batch_calls.append(list(deploymentIds))
            return {
                "deploymentsInfo": [
                    {
                        "deploymentId": i,
                        "createTime": dt(2026, 7, 1),
                        "completeTime": dt(2026, 7, 1, 0, 5, 0),
                        "creator": "user",
                    }
                    for i in deploymentIds
                ]
            }

        with (
            mock.patch.object(
                status.codedeploy,
                "list_deployments",
                side_effect=fake_list_deployments,
                create=True,
            ),
            mock.patch.object(
                status.codedeploy,
                "batch_get_deployments",
                side_effect=fake_batch_get_deployments,
                create=True,
            ),
        ):
            windows = status.codedeploy_windows(365)

        self.assertEqual([len(c) for c in batch_calls], [25, 5])
        self.assertEqual(len(windows), 30)
        self.assertEqual(windows[0], (dt(2026, 7, 1), dt(2026, 7, 1, 0, 5, 0)))

    def test_skips_deployment_with_no_complete_time(self):
        with (
            mock.patch.object(
                status.codedeploy,
                "list_deployments",
                return_value={"deployments": ["d-1", "d-2"]},
                create=True,
            ),
            mock.patch.object(
                status.codedeploy,
                "batch_get_deployments",
                return_value={
                    "deploymentsInfo": [
                        {
                            "deploymentId": "d-1",
                            "createTime": dt(2026, 7, 1),
                            "completeTime": dt(2026, 7, 1, 0, 5, 0),
                            "creator": "user",
                        },
                        # Still in flight -- no completeTime yet.
                        {
                            "deploymentId": "d-2",
                            "createTime": dt(2026, 7, 1),
                            "creator": "user",
                        },
                    ]
                },
                create=True,
            ),
        ):
            windows = status.codedeploy_windows(365)
        self.assertEqual(windows, [(dt(2026, 7, 1), dt(2026, 7, 1, 0, 5, 0))])

    def test_excludes_autoscaling_created_deployments(self):
        # A spot reclaim's replacement instance gets an autoscaling-created
        # deployment *inside* the outage it's a consequence of -- excluding
        # it as "planned maintenance" was the actual bug. user and
        # codeDeployRollback are kept; autoscaling is dropped; an unknown
        # future value is dropped too (allowlist, not a denylist).
        with (
            mock.patch.object(
                status.codedeploy,
                "list_deployments",
                return_value={"deployments": ["d-1", "d-2", "d-3", "d-4"]},
                create=True,
            ),
            mock.patch.object(
                status.codedeploy,
                "batch_get_deployments",
                return_value={
                    "deploymentsInfo": [
                        {
                            "deploymentId": "d-1",
                            "createTime": dt(2026, 7, 1),
                            "completeTime": dt(2026, 7, 1, 0, 5, 0),
                            "creator": "user",
                        },
                        {
                            "deploymentId": "d-2",
                            "createTime": dt(2026, 7, 2),
                            "completeTime": dt(2026, 7, 2, 0, 5, 0),
                            "creator": "autoscaling",
                        },
                        {
                            "deploymentId": "d-3",
                            "createTime": dt(2026, 7, 3),
                            "completeTime": dt(2026, 7, 3, 0, 5, 0),
                            "creator": "codeDeployRollback",
                        },
                        {
                            "deploymentId": "d-4",
                            "createTime": dt(2026, 7, 4),
                            "completeTime": dt(2026, 7, 4, 0, 5, 0),
                            "creator": "somethingUnrecognized",
                        },
                    ]
                },
                create=True,
            ),
        ):
            windows = status.codedeploy_windows(365)
        self.assertEqual(
            windows,
            [
                (dt(2026, 7, 1), dt(2026, 7, 1, 0, 5, 0)),
                (dt(2026, 7, 3), dt(2026, 7, 3, 0, 5, 0)),
            ],
        )

    def test_degrades_to_empty_list_on_failure(self):
        with mock.patch.object(
            status.codedeploy,
            "list_deployments",
            side_effect=RuntimeError("boom"),
            create=True,
        ):
            self.assertEqual(status.codedeploy_windows(365), [])


class PlannedWindowsUnionTests(unittest.TestCase):
    """planned_windows() -- the union of both sources. Each source already
    degrades to [] on its own failure (see EpisodeWindowsTests/
    CodedeployWindowsTests above), so this only needs to check the union
    itself, not failure handling a second time.
    """

    def test_returns_union_of_both_sources(self):
        episode_window = (dt(2026, 7, 15, 10, 0, 0), dt(2026, 7, 15, 10, 4, 0))
        deploy_window = (dt(2026, 7, 20, 0, 0, 0), dt(2026, 7, 20, 0, 5, 0))
        with (
            mock.patch.object(status, "episode_windows", return_value=[episode_window]),
            mock.patch.object(
                status, "codedeploy_windows", return_value=[deploy_window]
            ),
        ):
            self.assertEqual(
                status.planned_windows(365), [episode_window, deploy_window]
            )


class PipelineCommitsTests(unittest.TestCase):
    """pipeline_commits() -- {deployment_id: commit_sha}, joined from a
    ListActionExecutions page by pipelineExecutionId. CodeDeploy revisions on
    this pipeline are S3-sourced, so this is the only path back to the
    commit that triggered a deployment (see summarize_deployment()).
    """

    @staticmethod
    def _action(execution_id, stage, external_id):
        return {
            "pipelineExecutionId": execution_id,
            "stageName": stage,
            "output": {"executionResult": {"externalExecutionId": external_id}},
        }

    def test_joins_deploy_and_source_actions_by_execution(self):
        details = [
            self._action("exec-1", "Deploy", "d-AAA"),
            self._action("exec-1", "Build", "build-1"),
            self._action("exec-1", "Source", "sha1"),
            self._action("exec-2", "Deploy", "d-BBB"),
            self._action("exec-2", "Source", "sha2"),
        ]
        with mock.patch.object(
            status.codepipeline,
            "list_action_executions",
            return_value={"actionExecutionDetails": details},
            create=True,
        ):
            commits = status.pipeline_commits()
        self.assertEqual(commits, {"d-AAA": "sha1", "d-BBB": "sha2"})

    def test_skips_execution_missing_deploy_or_source_action(self):
        details = [
            # No Deploy action -- e.g. the pipeline failed before that stage.
            self._action("exec-1", "Source", "sha1"),
            self._action("exec-2", "Deploy", "d-BBB"),
            self._action("exec-2", "Source", "sha2"),
        ]
        with mock.patch.object(
            status.codepipeline,
            "list_action_executions",
            return_value={"actionExecutionDetails": details},
            create=True,
        ):
            commits = status.pipeline_commits()
        self.assertEqual(commits, {"d-BBB": "sha2"})

    def test_degrades_to_empty_dict_on_failure(self):
        with mock.patch.object(
            status.codepipeline,
            "list_action_executions",
            side_effect=RuntimeError("boom"),
            create=True,
        ):
            self.assertEqual(status.pipeline_commits(), {})


class SummarizeDeploymentTests(unittest.TestCase):
    """summarize_deployment(d, commits) resolves a commit SHA via a lookup
    into the id->sha map deployment_commits() builds, not gitHubLocation
    (always null on this pipeline; see pipeline_commits()). commit is a bare
    SHA; the frontend resolves it against the payload's top-level
    source_repo.
    """

    def test_populates_commit_when_deployment_id_is_in_map(self):
        d = {
            "deploymentId": "d-AAA",
            "status": "Succeeded",
            "createTime": dt(2026, 7, 15),
        }
        result = status.summarize_deployment(d, {"d-AAA": "abc123"})
        self.assertEqual(result["commit"], "abc123")

    def test_commit_is_none_when_deployment_id_is_absent_from_map(self):
        # The rollback case -- a rollback deployment is never a pipeline
        # action's own externalExecutionId, so it degrades to no commit,
        # which the frontend renders as --.
        d = {
            "deploymentId": "d-ROLLBACK",
            "status": "Succeeded",
            "createTime": dt(2026, 7, 15),
        }
        result = status.summarize_deployment(d, {})
        self.assertIsNone(result["commit"])

    def test_none_deployment_returns_none(self):
        self.assertIsNone(status.summarize_deployment(None, {}))


class DeploymentCommitsTests(unittest.TestCase):
    """deployment_commits(details, pipeline) -- extends pipeline_commits()'s
    own join to deployments Auto Scaling replayed verbatim: a deployment
    with no pipeline-attributed commit inherits the SHA of any other
    deployment in details that carries the identical S3 revision (same
    bucket/key/version -- same deployed bytes).
    """

    @staticmethod
    def _deployment(deployment_id, bucket="b", key="k", version="v1"):
        return {
            "deploymentId": deployment_id,
            "revision": {
                "s3Location": {"bucket": bucket, "key": key, "version": version}
            },
        }

    def test_direct_pipeline_hit_wins(self):
        details = [self._deployment("d-AAA")]
        commits = status.deployment_commits(details, {"d-AAA": "sha1"})
        self.assertEqual(commits, {"d-AAA": "sha1"})

    def test_asg_deployment_inherits_via_matching_revision(self):
        # d-AAA is the pipeline-triggered deployment; d-BBB is a later Auto
        # Scaling launch that redeployed the identical revision.
        details = [self._deployment("d-AAA"), self._deployment("d-BBB")]
        commits = status.deployment_commits(details, {"d-AAA": "sha1"})
        self.assertEqual(commits, {"d-AAA": "sha1", "d-BBB": "sha1"})

    def test_non_matching_revision_is_not_attributed(self):
        details = [
            self._deployment("d-AAA", version="v1"),
            self._deployment("d-BBB", version="v2"),
        ]
        commits = status.deployment_commits(details, {"d-AAA": "sha1"})
        self.assertEqual(commits, {"d-AAA": "sha1"})
        self.assertNotIn("d-BBB", commits)

    def test_missing_or_partial_s3_location_is_not_attributed(self):
        details = [
            {
                "deploymentId": "d-AAA",
                "revision": {"s3Location": {"bucket": "b", "key": "k"}},
            },
            {"deploymentId": "d-BBB"},
        ]
        commits = status.deployment_commits(details, {})
        self.assertEqual(commits, {})


if __name__ == "__main__":
    unittest.main()
