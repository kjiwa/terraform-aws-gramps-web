/**
 * The pure computations behind the Incidents card and the strip readout: the
 * page's time grid, per-cell incident counts, medians and percentiles, pool
 * grouping, the recovery split, the strip's time axis. No DOM; edges named in each title.
 */
import { describe, expect, it } from 'vitest';
import type { Change, Episode, Interruption } from '../../src/generated/status-payload.d.ts';
import { labelPlacement, niceTicks } from '../../src/status/charts/BarChart.tsx';
import {
  CAUSE_CLASSES,
  causeClass,
  isDeliberateChange,
  triggerLabel,
} from '../../src/status/causes.ts';
import {
  cellIncidents,
  cellLabel,
  incidentCounts,
  incidentsText,
  stripWindow,
} from '../../src/status/events.ts';
import { cellOf, gridFor, RANGE_ORDER } from '../../src/status/ranges.ts';
import {
  hasSpotActivity,
  median,
  percentile,
  poolTable,
  recoverySplit,
  summarize,
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

describe('gridFor and cellOf', () => {
  it('tiles each range with its own cell count back from the end', () => {
    const counts = RANGE_ORDER.map((k) => gridFor(k, NOW).count);
    expect(counts).toEqual([24, 28, 30, 90, 52]);
    const g = gridFor('7d', NOW);
    expect(g.endMs).toBe(NOW);
    expect(g.endMs - g.startMs).toBe(28 * 6 * 3600_000);
  });

  it('puts the start in the first cell and the end in the last, and nothing outside', () => {
    const g = gridFor('30d', NOW);
    expect(cellOf(g, g.startMs)).toBe(0);
    expect(cellOf(g, g.endMs)).toBe(29);
    expect(cellOf(g, g.startMs - 1)).toBe(-1);
    expect(cellOf(g, g.endMs + 1)).toBe(-1);
    expect(cellOf(g, g.startMs + DAY)).toBe(1);
  });
});

describe('incidentCounts', () => {
  it('stacks counts per cell in cause-class order, ignoring episodes outside the grid', () => {
    const g = gridFor('30d', NOW);
    const planned = { planned: true, cause: 'deploy' } as const;
    const counts = incidentCounts(g, [
      reclaim(NOW - 1000),
      reclaim(NOW - 2000),
      reclaim(NOW - 1000, planned),
      reclaim(NOW - 3 * DAY, { cause: 'health-replace' }),
      reclaim(NOW - 90 * DAY),
    ]);
    expect(counts).toHaveLength(30);
    expect(CAUSE_CLASSES.map((c) => c.id)).toEqual(['spot', 'planned', 'unplanned']);
    expect(counts[29]).toEqual([2, 1, 0]);
    expect(counts[27]).toEqual([0, 0, 1]);
    expect(counts.flat().reduce((a, n) => a + n, 0)).toBe(4);
  });
});

describe('cellLabel', () => {
  it('reads as an hour for sub-day cells, a date for day cells, a date span for week cells', () => {
    expect(cellLabel(gridFor('24h', NOW), 23).title).toBe('2026-06-17 11:00 UTC');
    expect(cellLabel(gridFor('30d', NOW), 29).title).toBe('2026-06-16');
    expect(cellLabel(gridFor('1y', NOW), 51).title).toBe('2026-06-10 – 2026-06-16');
  });
});

describe('summarize', () => {
  const win = (days: number) => ({ startMs: NOW - days * DAY, endMs: NOW });

  it('counts warnings and spot-reclaim episodes in the window', () => {
    const d = data(
      [reclaim(NOW - DAY), reclaim(NOW - DAY + 1000), reclaim(NOW - 40 * DAY)],
      [warning(NOW - DAY), warning(NOW - 2 * DAY), warning(NOW - 50 * DAY)],
    );
    const s = summarize(d, win(30));
    expect(s.reclaims).toBe(2);
    expect(s.outages).toBe(2);
  });

  it('reports the share of all episode downtime that was spot-reclaim', () => {
    const d = data([
      reclaim(NOW - 1 * DAY, { duration_s: 100 }),
      reclaim(NOW - 2 * DAY, { duration_s: 300 }),
      { ...reclaim(NOW - 3 * DAY, { duration_s: 600 }), cause: 'deploy', planned: true },
    ]);
    expect(summarize(d, win(30)).downtimeShare).toBeCloseTo(40);
  });

  it('has a null share when nothing is in the window', () => {
    const s = summarize(data([reclaim(NOW - 200 * DAY)]), win(30));
    expect(s).toEqual({ reclaims: 0, outages: 0, downtimeShare: null });
  });

  it('includes the exact window start and excludes a millisecond before it', () => {
    const start = NOW - 30 * DAY;
    expect(summarize(data([reclaim(start), reclaim(start - 1)]), win(30)).outages).toBe(1);
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

  it('counts a deploy as deliberate only for a user or a rollback, and any instance refresh', () => {
    const c = (creator: string | null, kind: Change['kind'] = 'deploy') => ({ kind, creator });
    expect(isDeliberateChange(c('user'))).toBe(true);
    expect(isDeliberateChange(c('codeDeployRollback'))).toBe(true);
    expect(isDeliberateChange(c('autoscaling'))).toBe(false);
    expect(isDeliberateChange(c(null, 'instance-refresh'))).toBe(true);
  });

  it('names the trigger of a change', () => {
    expect(triggerLabel({ kind: 'deploy', creator: 'codeDeployRollback' })).toBe('rollback');
    expect(triggerLabel({ kind: 'instance-refresh', creator: null })).toBe('refresh');
    expect(triggerLabel({ kind: 'deploy', creator: 'autoscaling' })).toBe('autoscaling');
  });
});

describe('strip incidents', () => {
  const cell = (label: string) => ({
    label,
    avg: 1,
    samples: 1,
    partial: false,
    expected_samples: 1,
  });

  it('reads the window start from each of the three cell label formats', () => {
    expect(stripWindow([cell('2026-06-15 14:00')], 3600)).toEqual({
      startMs: Date.parse('2026-06-15T14:00:00Z'),
      cellMs: 3600_000,
    });
    expect(stripWindow([cell('2026-06-15'), cell('2026-06-16')], 86400)?.startMs).toBe(
      Date.parse('2026-06-15T00:00:00Z'),
    );
    expect(stripWindow([cell('2026-07-13 – 2026-07-19')], 604800)?.startMs).toBe(
      Date.parse('2026-07-13T00:00:00Z'),
    );
  });

  it('has no window for an unparseable label or no cells', () => {
    expect(stripWindow([cell('week of')], 3600)).toBeNull();
    expect(stripWindow([], 3600)).toBeNull();
  });

  const window = { startMs: NOW - DAY, cellMs: 3600_000 };

  it('picks the episodes overlapping one cell, including one that began earlier', () => {
    const cellStart = window.startMs + 5 * 3600_000;
    const inside = reclaim(cellStart + 600_000);
    const earlier = reclaim(cellStart - 600_000, { duration_s: 1200 });
    const before = reclaim(cellStart - 7200_000);
    const after = reclaim(cellStart + 3600_000);
    expect(cellIncidents(window, 5, [inside, earlier, before, after])).toEqual([inside, earlier]);
  });

  it('treats a cell as half-open: an episode ending exactly at its start counts, one starting at its end does not', () => {
    const cellStart = window.startMs + 3600_000;
    expect(cellIncidents(window, 1, [reclaim(cellStart - 300_000)])).toHaveLength(1);
    expect(cellIncidents(window, 1, [reclaim(cellStart + 3600_000)])).toHaveLength(0);
  });

  it('names incidents by cause and duration, capped with a remainder', () => {
    expect(incidentsText([])).toBe('');
    expect(incidentsText([reclaim(NOW)])).toBe('1 incident: spot-reclaim 5m 0s');
    const causes = ['deploy', 'rightsize', 'backup', 'unknown', 'deploy'] as const;
    expect(incidentsText(causes.map((cause, i) => reclaim(NOW + i, { cause })))).toBe(
      '5 incidents: deploy 5m 0s, rightsize 5m 0s, backup 5m 0s, +2 more',
    );
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
