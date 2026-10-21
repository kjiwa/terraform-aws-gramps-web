import { fmtDate } from '../shared/format';

/**
 * Shared by every panel with a range selector (Reliability, Host, Assistant).
 * Render order for the tiles and the range-selector buttons; mirrors RANGES
 * in lambda/status.py so the two never drift, and lets the frontend stay
 * ignorant of which underlying CloudWatch query backs which range (that
 * bookkeeping is entirely server-side).
 */
export const RANGE_ORDER = ['24h', '7d', '30d', '90d', '1y'] as const;
export type RangeKey = (typeof RANGE_ORDER)[number];

/**
 * One opening window for every card: a per-panel default is really a claim
 * about how much history that panel happens to have, which drifts as the
 * deployment ages. Cards stay independently switchable after load.
 */
export const DEFAULT_RANGE: RangeKey = '30d';

/** available: the range keys with data, in RANGE_ORDER's display order. */
export function availableRanges(has: (key: RangeKey) => boolean): RangeKey[] {
  return RANGE_ORDER.filter(has);
}

/** The default range if it has data, else the first available one. */
export function defaultSelected(available: RangeKey[]): RangeKey | undefined {
  return available.includes(DEFAULT_RANGE) ? DEFAULT_RANGE : available[0];
}

/**
 * Each range key's own human window, in seconds -- CHART_RANGES' (period_s,
 * cells) in lambda/status.py always name a span that divides it exactly
 * (24h = 48*1800s, 7d = 168*3600s, 30d/90d/1y = n*86400s), so a cell's width
 * is this window divided by however many cells the payload actually shipped
 * for that key, not a second guess at the server's cadence. Exported for
 * WindowNav.tsx: a pan moves the window by exactly one of its own spans.
 */
export const RANGE_SPAN_S: Record<RangeKey, number> = {
  '24h': 24 * 3600,
  '7d': 7 * 86400,
  '30d': 30 * 86400,
  '90d': 90 * 86400,
  '1y': 365 * 86400,
};

/**
 * How far in the past the middle of cell `index` (of `count`) sits within
 * `range`'s window -- approximate ("≈"), since a cell spans a duration, not
 * an instant. Host/Assistant's charts carry no timestamps, and Host.tsx
 * deliberately never fabricates a clock time from a bucket count (see
 * capacityText()'s neighboring comment) -- this isn't that: it's the
 * range's own known span divided across its own known cell count, a fact
 * the payload already implies rather than a synthesized cadence.
 *
 * pannedEnd: the server's own echoed /_status/series `end` (see series.ts),
 * when the caller is showing a panned window rather than the live one --
 * "≈3d ago" is false once the window no longer ends at now, so this reads
 * "≈3d before <pannedEnd>" instead. Omit it (or pass null) for the live,
 * unpanned case, which keeps the original "X ago" phrasing unchanged.
 */
export function relativeLabel(
  range: RangeKey,
  index: number,
  count: number,
  pannedEnd?: string | null,
): string {
  if (count <= 0) return 'now';
  const cellWidth = RANGE_SPAN_S[range] / count;
  const agoS = (count - 1 - index + 0.5) * cellWidth;
  const phrase = (base: string) =>
    pannedEnd ? `${base} before ${fmtDate(pannedEnd)}` : agoS < 60 ? base : `${base} ago`;
  if (agoS < 60) return phrase('≈now');
  const minutes = agoS / 60;
  if (minutes < 60) return phrase(`≈${Math.round(minutes)}m`);
  const hours = minutes / 60;
  if (hours < 24) return phrase(`≈${Math.round(hours)}h`);
  return phrase(`≈${Math.round(hours / 24)}d`);
}

/**
 * Host/Storage/Assistant's LineChart opts.xStart/xEnd -- "<range> ago" /
 * "now" is the same "false when panned" defect relativeLabel's own
 * pannedEnd param exists to fix, applied to the chart's axis labels rather
 * than its scrub readout. pannedEnd is the server's echoed /_status/series
 * `end` (see series.ts); omit it (or pass null) for the live, unpanned
 * case, which keeps the original labels unchanged.
 */
export function windowAxisLabels(
  range: RangeKey | undefined,
  pannedEnd?: string | null,
): { xStart: string; xEnd: string } {
  if (!pannedEnd) return { xStart: `${range} ago`, xEnd: 'now' };
  return { xStart: `${range} before ${fmtDate(pannedEnd)}`, xEnd: fmtDate(pannedEnd) };
}
