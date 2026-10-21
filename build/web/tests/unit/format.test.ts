import { describe, expect, it } from 'vitest';
import { fmtDay, fmtDuration, fmtStamp } from '../../src/shared/format.ts';

describe('fmtDuration', () => {
  it('keeps the short forms below 48 hours', () => {
    expect(fmtDuration(45)).toBe('45s');
    expect(fmtDuration(125)).toBe('2m 5s');
    expect(fmtDuration(3 * 3600 + 60)).toBe('3h 1m');
    expect(fmtDuration(47 * 3600 + 59 * 60 + 59)).toBe('47h 59m');
  });

  it('switches to days and hours at exactly 48 hours', () => {
    expect(fmtDuration(48 * 3600)).toBe('2d 0h');
    expect(fmtDuration(48 * 3600 + 3599)).toBe('2d 0h');
    expect(fmtDuration(153 * 3600 + 58 * 60)).toBe('6d 9h');
    expect(fmtDuration(154 * 3600)).toBe('6d 10h');
  });

  it('shows a dash for no value', () => {
    expect(fmtDuration(null)).toBe('—');
  });
});

describe('table timestamps', () => {
  it('compacts to minutes, or to the day, in UTC', () => {
    expect(fmtStamp('2026-06-13T21:36:45Z')).toBe('2026-06-13 21:36');
    expect(fmtDay('2026-06-13T21:36:45Z')).toBe('2026-06-13');
    expect(fmtStamp(undefined)).toBe('—');
    expect(fmtDay(null)).toBe('—');
  });
});
