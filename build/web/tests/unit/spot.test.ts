/**
 * The pure computations behind the Spot panel and the events lane: week
 * bucketing, medians and percentiles, the absorbed rule, pool grouping, the
 * recovery split, the lane's time axis. No DOM; edges named in each title.
 */
import { describe, expect, it } from 'vitest';
import type { Change, Episode, Interruption } from '../../src/generated/status-payload.d.ts';
import { labelPlacement, niceTicks } from '../../src/status/charts/BarChart.tsx';
import { causeClass, isDeliberateDeploy, triggerLabel } from '../../src/status/causes.ts';
import { laneEvents, lanePercent, laneSpan, laneWindow } from '../../src/status/events.ts';
import {
  hasSpotActivity,
  median,
  percentile,
  poolTable,
  recoverySplit,
  summarize,
  weeklyBuckets,
  weekStartMs,
  type SpotData,
} from '../../src/status/spot.ts';

const NOW = Date.parse('2026-06-17T12:00:00Z'); // a Wednesday
const DAY = 86400_000;

function iso(ms: number): string {
  return new Date(ms).toISOString();
}

function reclaim(startedMs: number, extra: Partial<Episode> = {}): Episode {
  return {
    started: iso(startedMs),
    duration_s: 300,
    cause: 'spot-reclaim',
    planned: false,
    ...extra,
  };
}

function warning(timeMs: number): Interruption {
  return { time: iso(timeMs), instance_id: 'i-1', action: 'terminate' };
}

function data(episodes: Episode[] = [], warnings: Interruption[] = []): SpotData {
  return { episodes, warnings };
}

describe('weekStartMs', () => {
  it('snaps to Monday 00:00 UTC, with Sunday night still in the earlier week', () => {
    expect(iso(weekStartMs(Date.parse('2026-06-17T12:00:00Z')))).toBe('2026-06-15T00:00:00.000Z');
    expect(iso(weekStartMs(Date.parse('2026-06-15T00:00:00Z')))).toBe('2026-06-15T00:00:00.000Z');
    expect(iso(weekStartMs(Date.parse('2026-06-14T23:59:59Z')))).toBe('2026-06-08T00:00:00.000Z');
  });

  it('is independent of local DST: the weeks around a US spring-forward are 7 days apart', () => {
    const before = weekStartMs(Date.parse('2026-03-05T12:00:00Z'));
    const after = weekStartMs(Date.parse('2026-03-12T12:00:00Z'));
    expect(after - before).toBe(7 * DAY);
  });

  it('handles the epoch (a Thursday) and times before it', () => {
    expect(iso(weekStartMs(0))).toBe('1969-12-29T00:00:00.000Z');
    expect(iso(weekStartMs(-1))).toBe('1969-12-29T00:00:00.000Z');
  });
});

describe('median and percentile', () => {
  it('return null for no data', () => {
    expect(median([])).toBeNull();
    expect(percentile([], 0.9)).toBeNull();
  });

  it('read a single point as itself', () => {
    expect(median([7])).toBe(7);
    expect(percentile([7], 0.9)).toBe(7);
  });

  it('average the middle pair for an even sample, and use nearest rank for p90', () => {
    expect(median([4, 1, 3, 2])).toBe(2.5);
    expect(percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.9)).toBe(9);
    expect(percentile([10, 1], 0.9)).toBe(10);
  });
});

describe('weeklyBuckets', () => {
  it('with no data still spans the range, every week at zero', () => {
    const weeks = weeklyBuckets(data(), '30d', NOW);
    expect(weeks.length).toBeGreaterThanOrEqual(5);
    expect(weeks.every((w) => w.outages === 0 && w.absorbed === 0)).toBe(true);
    expect(weeks[weeks.length - 1]?.start).toBe('2026-06-15T00:00:00.000Z');
  });

  it('counts warnings with no episodes as absorbed', () => {
    const weeks = weeklyBuckets(data([], [warning(NOW - DAY), warning(NOW - 2 * DAY)]), '30d', NOW);
    expect(weeks.reduce((a, w) => a + w.absorbed, 0)).toBe(2);
    expect(weeks.reduce((a, w) => a + w.outages, 0)).toBe(0);
  });

  it('counts episodes with no warnings as outages and floors absorbed at zero', () => {
    const weeks = weeklyBuckets(data([reclaim(NOW - DAY), reclaim(NOW - 2 * DAY)]), '30d', NOW);
    expect(weeks.reduce((a, w) => a + w.outages, 0)).toBe(2);
    expect(weeks.every((w) => w.absorbed === 0)).toBe(true);
  });

  it('includes the exact range start and excludes a millisecond before it', () => {
    const start = NOW - 30 * DAY;
    const weeks = weeklyBuckets(data([reclaim(start), reclaim(start - 1)]), '30d', NOW);
    expect(weeks.reduce((a, w) => a + w.outages, 0)).toBe(1);
  });

  it('ignores episodes of other causes', () => {
    const other = reclaim(NOW - DAY, { cause: 'deploy', planned: true });
    expect(weeklyBuckets(data([other]), '30d', NOW).every((w) => w.outages === 0)).toBe(true);
  });
});

describe('summarize', () => {
  it('sums absorbed per week, so a surplus of outages in one week cannot cancel another week', () => {
    const lastWeek = NOW - 9 * DAY;
    const thisWeek = NOW - DAY;
    const d = data(
      [reclaim(lastWeek), reclaim(lastWeek + 1000), reclaim(thisWeek)],
      [
        warning(lastWeek),
        warning(thisWeek - 1000),
        warning(thisWeek - 2000),
        warning(thisWeek - 3000),
      ],
    );
    const s = summarize(d, '30d', NOW);
    expect(s.reclaims).toBe(4);
    expect(s.outages).toBe(3);
    expect(s.absorbed).toBe(2);
  });

  it('reports downtime, its share of all episodes, and median with p90', () => {
    const d = data([
      reclaim(NOW - 1 * DAY, { duration_s: 100 }),
      reclaim(NOW - 2 * DAY, { duration_s: 300 }),
      { ...reclaim(NOW - 3 * DAY, { duration_s: 600 }), cause: 'deploy', planned: true },
    ]);
    const s = summarize(d, '30d', NOW);
    expect(s.downtimeS).toBe(400);
    expect(s.downtimeShare).toBeCloseTo(40);
    expect(s.medianS).toBe(200);
    expect(s.p90S).toBe(300);
  });

  it('has null share and recovery when nothing is in range', () => {
    const s = summarize(data([reclaim(NOW - 200 * DAY)]), '30d', NOW);
    expect(s).toMatchObject({ reclaims: 0, outages: 0, absorbed: 0, downtimeS: 0 });
    expect(s.downtimeShare).toBeNull();
    expect(s.medianS).toBeNull();
    expect(s.p90S).toBeNull();
  });

  it('widens with the range', () => {
    const d = data([reclaim(NOW - 60 * DAY), reclaim(NOW - 200 * DAY)]);
    expect(summarize(d, '30d', NOW).outages).toBe(0);
    expect(summarize(d, '90d', NOW).outages).toBe(1);
    expect(summarize(d, '1y', NOW).outages).toBe(2);
  });
});

describe('hasSpotActivity', () => {
  it('is true for a warning or a spot-reclaim episode only', () => {
    expect(hasSpotActivity(data())).toBe(false);
    expect(hasSpotActivity(data([reclaim(NOW, { cause: 'deploy' })]))).toBe(false);
    expect(hasSpotActivity(data([reclaim(NOW)]))).toBe(true);
    expect(hasSpotActivity(data([], [warning(NOW)]))).toBe(true);
  });
});

describe('recoverySplit', () => {
  const timed = (wait: number, boot: number) =>
    reclaim(NOW, { capacity_wait_s: wait, boot_to_serve_s: boot });

  it('withholds the bar below three timed outages and reports how many carry timing', () => {
    const r = recoverySplit([timed(60, 30), timed(90, 30), reclaim(NOW)]);
    expect(r).toEqual({ timed: 2, split: null });
  });

  it('takes medians over the outages that carry both fields', () => {
    const r = recoverySplit([timed(60, 30), timed(90, 40), timed(120, 50), reclaim(NOW)]);
    expect(r.timed).toBe(3);
    expect(r.split).toEqual({ count: 3, capacityWaitS: 90, bootToServeS: 40 });
  });

  it('skips an outage with only one of the two fields or null timings', () => {
    const half = reclaim(NOW, { capacity_wait_s: 60, boot_to_serve_s: null });
    expect(recoverySplit([half, half, half]).timed).toBe(0);
  });
});

describe('poolTable', () => {
  const instance = (type: string, az: string, lifetimeS?: number) => ({
    id: 'i-x',
    type,
    az,
    arch: 'arm64',
    launched: '2026-06-01T00:00:00Z',
    ...(lifetimeS === undefined
      ? {}
      : { time: iso(Date.parse('2026-06-01T00:00:00Z') + lifetimeS * 1000) }),
  });
  const lost = (n: number, type: string, az: string, lifetimeS?: number) =>
    reclaim(NOW - n * DAY, { old_instance: instance(type, az, lifetimeS) });

  it('has no rows for no episodes', () => {
    expect(poolTable([])).toEqual([]);
  });

  it('groups by type and az, most reclaims first, with median lifetime and last reclaim', () => {
    const rows = poolTable([
      lost(5, 'm8g.medium', 'us-east-1b', 3600),
      lost(1, 'm8g.medium', 'us-east-1b', 7200),
      lost(3, 'm7g.medium', 'us-east-1a', 600),
      lost(2, 'm8g.medium', 'us-east-1c', 100),
    ]);
    expect(rows.map((r) => [r.type, r.az, r.reclaims])).toEqual([
      ['m8g.medium', 'us-east-1b', 2],
      ['m8g.medium', 'us-east-1c', 1],
      ['m7g.medium', 'us-east-1a', 1],
    ]);
    expect(rows[0]?.medianLifetimeS).toBe(5400);
    expect(rows[0]?.last).toBe(iso(NOW - DAY));
  });

  it('folds everything past the sixth row into one Other row', () => {
    const eps = Array.from({ length: 8 }, (_, i) => lost(i + 1, `t${i}.large`, 'us-east-1a'));
    const rows = poolTable(eps);
    expect(rows).toHaveLength(7);
    expect(rows[6]).toMatchObject({ type: 'Other', az: '', reclaims: 2 });
  });

  it('shows 6 pools as is, 7 pools with the seventh on its own row, 8 pools with Other', () => {
    const pools = (n: number) =>
      poolTable(Array.from({ length: n }, (_, i) => lost(i + 1, `t${i}.large`, 'us-east-1a')));
    expect(pools(6).map((r) => r.type)).not.toContain('Other');
    expect(pools(6)).toHaveLength(6);
    const seven = pools(7);
    expect(seven).toHaveLength(7);
    expect(seven.map((r) => r.type)).not.toContain('Other');
    expect(seven[6]?.reclaims).toBe(1);
    const eight = pools(8);
    expect(eight).toHaveLength(7);
    expect(eight[6]).toMatchObject({ type: 'Other', reclaims: 2 });
  });

  it('counts a reclaim with no old_instance record as an unknown pool, with no lifetime', () => {
    const rows = poolTable([reclaim(NOW)]);
    expect(rows).toEqual([
      { type: 'unknown', az: '—', reclaims: 1, medianLifetimeS: null, last: iso(NOW) },
    ]);
  });
});

describe('niceTicks', () => {
  it('never exceeds four ticks including zero, and ends at or above the max', () => {
    for (const max of [0, 1, 2, 3, 4, 7, 9, 10, 23, 99, 101, 1234]) {
      const ticks = niceTicks(max);
      expect(ticks.length).toBeLessThanOrEqual(4);
      expect(ticks[0]).toBe(0);
      expect(ticks[ticks.length - 1]).toBeGreaterThanOrEqual(max);
      expect(ticks.every(Number.isInteger)).toBe(true);
    }
  });

  it('draws a one-step axis for an empty chart', () => {
    expect(niceTicks(0)).toEqual([0, 1]);
  });
});

describe('cause classes', () => {
  it('separates spot reclaims from planned and unplanned causes', () => {
    expect(causeClass({ cause: 'spot-reclaim', planned: false })).toBe('spot');
    expect(causeClass({ cause: 'deploy', planned: true })).toBe('planned');
    expect(causeClass({ cause: 'health-replace', planned: false })).toBe('unplanned');
  });

  it('counts a deploy as deliberate only for a user or a rollback', () => {
    const c = (creator: string | null, kind: Change['kind'] = 'deploy') => ({ kind, creator });
    expect(isDeliberateDeploy(c('user'))).toBe(true);
    expect(isDeliberateDeploy(c('codeDeployRollback'))).toBe(true);
    expect(isDeliberateDeploy(c('autoscaling'))).toBe(false);
    expect(isDeliberateDeploy(c(null, 'instance-refresh'))).toBe(false);
  });

  it('names the trigger of a change', () => {
    expect(triggerLabel({ kind: 'deploy', creator: 'codeDeployRollback' })).toBe('rollback');
    expect(triggerLabel({ kind: 'instance-refresh', creator: null })).toBe('refresh');
    expect(triggerLabel({ kind: 'deploy', creator: 'autoscaling' })).toBe('autoscaling');
  });
});

describe('events lane', () => {
  const cell = (label: string) => ({
    label,
    avg: 1,
    samples: 1,
    partial: false,
    expected_samples: 1,
  });

  it('reads the window start from each of the three cell label formats', () => {
    expect(laneWindow([cell('2026-06-15 14:00')], 3600)).toEqual({
      startMs: Date.parse('2026-06-15T14:00:00Z'),
      endMs: Date.parse('2026-06-15T15:00:00Z'),
    });
    expect(laneWindow([cell('2026-06-15'), cell('2026-06-16')], 86400)?.endMs).toBe(
      Date.parse('2026-06-17T00:00:00Z'),
    );
    expect(laneWindow([cell('2026-07-13 – 2026-07-19')], 604800)?.startMs).toBe(
      Date.parse('2026-07-13T00:00:00Z'),
    );
  });

  it('has no window for an unparseable label or no cells', () => {
    expect(laneWindow([cell('week of')], 3600)).toBeNull();
    expect(laneWindow([], 3600)).toBeNull();
  });

  const window = { startMs: NOW - DAY, endMs: NOW };
  const change = (
    atMs: number,
    creator: string | null,
    kind: Change['kind'] = 'deploy',
  ): Change => ({
    at: iso(atMs),
    kind,
    id: 'x',
    creator,
    outcome: 'succeeded',
    duration_s: 10,
    description: null,
    outage: false,
  });

  it('keeps episodes and deliberate deploys inside the window, in time order', () => {
    const events = laneEvents(
      window,
      [reclaim(NOW - 3600_000), reclaim(NOW - 2 * DAY), reclaim(NOW)],
      [
        change(NOW - 7200_000, 'user'),
        change(NOW - 1800_000, 'autoscaling'),
        change(NOW - 900_000, null, 'instance-refresh'),
      ],
    );
    expect(events.map((e) => e.kind)).toEqual(['deploy', 'episode']);
    expect(events[0]?.at).toBe(iso(NOW - 7200_000));
  });

  it('keeps an episode that began before the window or runs past its end, drops one entirely outside', () => {
    const events = laneEvents(
      window,
      [
        reclaim(window.startMs - 600_000, { duration_s: 1200 }),
        reclaim(window.endMs - 60_000, { duration_s: 3600 }),
        reclaim(window.startMs - 2 * DAY, { duration_s: 300 }),
        reclaim(window.endMs + 60_000, { duration_s: 300 }),
      ],
      [],
    );
    expect(events).toHaveLength(2);
  });

  it('treats the window edges as inside: an episode ending exactly at the start counts, one starting exactly at the end does not', () => {
    const atStart = reclaim(window.startMs - 300_000, { duration_s: 300 });
    const atEnd = reclaim(window.endMs, { duration_s: 300 });
    expect(laneEvents(window, [atStart], [])).toHaveLength(1);
    expect(laneEvents(window, [atEnd], [])).toHaveLength(0);
  });

  it('clamps a mark to the lane', () => {
    const early = laneSpan(window, iso(window.startMs - DAY / 4), DAY / 2000);
    expect(early.left).toBe(0);
    expect(early.width).toBeCloseTo(25);
    const late = laneSpan(window, iso(window.endMs - DAY / 10), DAY / 1000);
    expect(late.left).toBeCloseTo(90);
    expect(late.width).toBeCloseTo(10);
    expect(late.left + late.width).toBeLessThanOrEqual(100.0001);
  });

  it('is empty for an empty window, so the lane renders nothing', () => {
    expect(laneEvents(window, [], [])).toEqual([]);
  });

  it('places an instant as a percentage of the window', () => {
    expect(lanePercent(window, iso(NOW - DAY / 2))).toBe(50);
  });
});

describe('labelPlacement', () => {
  const place = (cx: number) => labelPlacement(cx, 60, 20, 300);

  it('centers a label that fits inside the plot', () => {
    expect(place(150)).toEqual({ x: 150, anchor: 'middle' });
    expect(place(50)).toEqual({ x: 50, anchor: 'middle' });
  });

  it('start-anchors a label that would overhang the left edge', () => {
    expect(place(30)).toEqual({ x: 20, anchor: 'start' });
    expect(place(49)).toEqual({ x: 20, anchor: 'start' });
  });

  it('end-anchors a label that would overhang the right edge', () => {
    expect(place(290)).toEqual({ x: 300, anchor: 'end' });
    expect(place(271)).toEqual({ x: 300, anchor: 'end' });
    expect(place(270)).toEqual({ x: 270, anchor: 'middle' });
  });
});
