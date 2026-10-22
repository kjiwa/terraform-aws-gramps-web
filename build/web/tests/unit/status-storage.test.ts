/**
 * The Storage panel's percent-of-capacity disk chart: dividing the same
 * measured `disk_used_bytes_*` / `disk_total_bytes_*` pair the byte path
 * already carries, rather than plotting raw bytes on an auto-scaled axis.
 * pctRange/pctCurrent are pure and exported from Storage.tsx -- tested directly
 * here, the same style ranges.ts's relativeLabel gets in status-inspect.test.ts
 * -- plus one mounted-page check that the real fixture wires through to the
 * resting legend.
 */
import { describe, expect, it } from 'vitest';
import type { HostMetricSeries } from '../../src/generated/status-payload.d.ts';
import { pctCurrent, pctRange } from '../../src/status/panels/Storage.tsx';
import { mountStatus } from '../support/mount.ts';
import { metadata, payloadFor } from '../support/payload.ts';
import { ALL_TOGGLES_ON } from '../support/shell.ts';

function series(current: number | null, thirtyDay: (number | null)[]): HostMetricSeries {
  return { current, ranges: { '30d': thirtyDay } };
}

describe('pctRange', () => {
  it('divides each cell by its own total, not the series current', () => {
    const used = series(100, [50, 100, 150]);
    const total = series(1000, [500, 1000, 1500]);
    expect(pctRange(used, total, '30d')).toEqual([10, 10, 10]);
  });

  it('a mid-range volume resize renders as a step, not a restated history', () => {
    // A resize from 500 to 1000 partway through the window: the same
    // absolute used bytes reads as a smaller percent after the resize.
    // Dividing every cell by the current (post-resize) total of 1000 would
    // instead read 10% for every cell, erasing the step.
    const used = series(100, [50, 50, 100, 100]);
    const total = series(1000, [500, 500, 1000, 1000]);
    expect(pctRange(used, total, '30d')).toEqual([10, 10, 10, 10]);
    const usedResizeCase = series(100, [50, 50, 50, 50]);
    expect(pctRange(usedResizeCase, total, '30d')).toEqual([10, 10, 5, 5]);
  });

  it('a null or zero-or-negative total cell renders a gap, never Infinity or NaN', () => {
    const used = series(100, [50, 50, 50]);
    const total = series(1000, [500, 0, null]);
    expect(pctRange(used, total, '30d')).toEqual([10, null, null]);
  });

  it('a null used cell renders a gap', () => {
    const used = series(100, [50, null]);
    const total = series(1000, [500, 500]);
    expect(pctRange(used, total, '30d')).toEqual([10, null]);
  });

  it('returns undefined when either series lacks the range entirely', () => {
    const used = series(100, [50]);
    const total: HostMetricSeries = { current: 1000, ranges: {} };
    expect(pctRange(used, total, '30d')).toBeUndefined();
    expect(pctRange(undefined, series(1000, [500]), '30d')).toBeUndefined();
  });
});

describe('pctCurrent', () => {
  it('divides the two series own current scalars', () => {
    expect(pctCurrent(series(50, []), series(500, []))).toBe(10);
  });

  it('is null when the total is missing, zero, or negative', () => {
    expect(pctCurrent(series(50, []), series(0, []))).toBeNull();
    expect(pctCurrent(series(50, []), series(null, []))).toBeNull();
    expect(pctCurrent(series(50, []), undefined)).toBeNull();
  });

  it('is null when used is missing', () => {
    expect(pctCurrent(series(null, []), series(500, []))).toBeNull();
  });
});

function storageCard(document: Document): Element {
  const card = Array.from(document.querySelectorAll('.card')).find(
    (c) => c.querySelector('h3')?.textContent === 'Storage',
  );
  if (!card) throw new Error('status-storage: Storage card not found');
  return card;
}

describe('Storage panel: resting legend', () => {
  it('reads percent of capacity with bytes in parentheses', async () => {
    const mounted = mountStatus({
      toggles: ALL_TOGGLES_ON,
      tokens: { access: 'test-access-token' },
      routes: {
        data: [{ status: 200, body: payloadFor(ALL_TOGGLES_ON) }],
        metadata: [{ status: 200, body: metadata() }],
      },
    });
    await mounted.settled();
    expect(mounted.pageErrors).toEqual([]);

    const legend = storageCard(mounted.document).querySelector('.chart-key')?.textContent;
    // Fixture: disk_used_bytes_data.current=214223698, disk_total_bytes_data.current=21045336064.
    expect(legend).toContain('data 1.0% (204.3 MiB)');
    // Fixture: disk_used_bytes_root.current=5726623744, disk_total_bytes_root.current=16857747456.
    expect(legend).toContain('root 34.0% (5.3 GiB)');
  });
});
