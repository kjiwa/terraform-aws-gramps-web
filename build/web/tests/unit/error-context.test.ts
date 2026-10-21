import { describe, expect, it } from 'vitest';
import { clearTime, contextLine } from '../../src/error/context.ts';

const NOW = Date.parse('2026-06-15T12:00:00Z');
const DAY = 86_400_000;

function ep(daysAgo: number, duration_s: number): Record<string, unknown> {
  return {
    started: new Date(NOW - daysAgo * DAY).toISOString(),
    duration_s,
    cause: 'spot-reclaim',
    planned: false,
  };
}

describe('contextLine', () => {
  it('says there were none when the window is empty', () => {
    expect(contextLine({ incidents: [] }, NOW)).toBe('No outages in the last 30 days.');
  });

  it('counts one outage without a median claim', () => {
    expect(contextLine({ incidents: [ep(1, 300)] }, NOW)).toBe(
      '1 earlier outage in the last 30 days.',
    );
  });

  it('counts two outages without a median claim', () => {
    expect(contextLine({ incidents: [ep(1, 300), ep(2, 60)] }, NOW)).toBe(
      '2 earlier outages in the last 30 days.',
    );
  });

  it('reports the median from three outages', () => {
    expect(contextLine({ incidents: [ep(1, 60), ep(2, 300), ep(3, 900)] }, NOW)).toBe(
      'In the last 30 days this site had 3 outages. The median took 5 minutes to clear.',
    );
  });

  it('averages the middle pair for an even count', () => {
    const incidents = [ep(1, 240), ep(2, 360), ep(3, 60), ep(4, 900)];
    expect(contextLine({ incidents }, NOW)).toContain('The median took 5 minutes to clear.');
  });

  it('shows at least 1 minute, singular', () => {
    const incidents = [ep(1, 10), ep(2, 20), ep(3, 40)];
    expect(contextLine({ incidents }, NOW)).toContain('The median took 1 minute to clear.');
  });

  it('rounds to whole minutes', () => {
    const incidents = [ep(1, 330), ep(2, 330), ep(3, 330)];
    expect(contextLine({ incidents }, NOW)).toContain('took 6 minutes to clear');
  });

  it('switches to hours at 60 minutes', () => {
    const incidents = [ep(1, 4500), ep(2, 4500), ep(3, 4500)];
    expect(contextLine({ incidents }, NOW)).toContain('took 1 hour 15 minutes to clear');
  });

  it('includes an episode exactly 30 days old and excludes an older one', () => {
    expect(contextLine({ incidents: [ep(30, 300)] }, NOW)).toBe(
      '1 earlier outage in the last 30 days.',
    );
    expect(
      contextLine(
        { incidents: [{ ...ep(30, 300), started: new Date(NOW - 30 * DAY - 1).toISOString() }] },
        NOW,
      ),
    ).toBe('No outages in the last 30 days.');
  });

  it('skips malformed entries', () => {
    const incidents = [
      null,
      'x',
      {},
      { started: 'not a date', duration_s: 60 },
      { started: new Date(NOW).toISOString(), duration_s: 'long' },
      { started: new Date(NOW).toISOString(), duration_s: -5 },
      { started: new Date(NOW).toISOString(), duration_s: Infinity },
      { started: 5, duration_s: 60 },
      ep(1, 120),
    ];
    expect(contextLine({ incidents }, NOW)).toBe('1 earlier outage in the last 30 days.');
  });

  it('returns null on a schema mismatch', () => {
    expect(contextLine(null, NOW)).toBeNull();
    expect(contextLine('x', NOW)).toBeNull();
    expect(contextLine({}, NOW)).toBeNull();
    expect(contextLine({ incidents: { error: 'boom' } }, NOW)).toBeNull();
  });
});

describe('clearTime', () => {
  it.each([
    [10, '1 minute'],
    [59 * 60, '59 minutes'],
    [60 * 60, '1 hour'],
    [61 * 60, '1 hour 1 minute'],
    [125 * 60, '2 hours 5 minutes'],
    [47 * 3600, '47 hours'],
    [48 * 3600, '2 days'],
    [60 * 3600, '3 days'],
  ])('%i s reads %s', (seconds, text) => {
    expect(clearTime(seconds)).toBe(text);
  });
});
