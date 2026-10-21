import type { ComponentChildren } from 'preact';
import { useRef } from 'preact/hooks';
import { createScrubHandlers } from '../inspect';
import { useChartSize } from './useChartSize';

/**
 * Render is a pure function of (measured size from useChartSize, series,
 * opts), so a parent re-rendering this same instance with new `series`/
 * `opts` (a range/toggle switch) redraws automatically on the next render
 * pass with no extra plumbing.
 */

export interface ChartSeries {
  values: (number | null | undefined)[];
  colorVar: string;
}

export interface LineChartOpts {
  min?: number;
  max?: number;
  yFormat?: (v: number) => string;
  xStart?: string;
  xEnd?: string;
  ariaLabel?: string;
  compact?: boolean;
  /**
   * Plain-text description of a given sample index, for the scrub overlay's
   * aria-valuetext (see the `inspect` prop below) -- normally the same
   * values the caller's own <Inspector> readout shows, in prose rather than
   * that readout's LegendPair markup. Falls back to a generic per-series
   * value list when omitted, so `inspect` still works (just less
   * descriptively) without every caller wiring this up.
   */
  describeIndex?: (index: number) => string;
}

export interface ChartInspect {
  /** null = resting (no pointer/keyboard focus scrubbing this chart). */
  index: number | null;
  onIndex: (i: number | null) => void;
}

/**
 * Smallest of {1, 2, 2.5, 5, 10} x 10^n at or above v -- keeps every
 * gridline tick a clean, easily-compared number instead of a fraction of
 * whatever the raw data max happens to be.
 */
function niceMax(v: number): number {
  if (!isFinite(v) || v <= 0) return 1;
  const pow = Math.pow(10, Math.floor(Math.log(v) / Math.LN10));
  const steps = [1, 2, 2.5, 5, 10];
  for (const step of steps) {
    if (step * pow >= v) return step * pow;
  }
  return 10 * pow;
}

// Axis labels sit inside the plot, so a data line can run through one; a
// card-colored halo keeps the text legible without moving it.
const HALO = {
  stroke: 'var(--gw-card)',
  'stroke-width': 3,
  'stroke-linejoin': 'round',
  'paint-order': 'stroke',
} as const;

function buildSvg(
  w: number,
  h: number,
  seriesArr: ChartSeries[],
  opts: LineChartOpts,
  activeIndex: number | null,
) {
  let count = 0;
  for (const s of seriesArr) count = Math.max(count, s.values.length);

  const allValues: number[] = [];
  for (const s of seriesArr) {
    for (const v of s.values) {
      if (v !== null && v !== undefined) allValues.push(v);
    }
  }
  const min = opts.min !== undefined ? opts.min : 0;
  let max =
    opts.max !== undefined
      ? opts.max
      : niceMax(Math.max(allValues.length ? Math.max(...allValues) : 1, 1));
  if (max <= min) max = min + 1; // degenerate flat series still gets a drawable range

  // Read once per draw, not hardcoded: this is the only text on the page
  // that would otherwise ignore the user's own font-size preference.
  const rootFontPx = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16;
  const labelPx = rootFontPx * 0.72;
  const padTop = labelPx + 4;
  const padBottom = labelPx + 6;
  const plotH = h - padTop - padBottom;
  function y(v: number): number {
    const frac = Math.max(0, Math.min(1, (v - min) / (max - min)));
    return padTop + plotH - frac * plotH;
  }

  const children: ComponentChildren[] = [];
  // Painted after the series so a halo can clear a line running through one.
  const labels: ComponentChildren[] = [];

  // Ticks at [min, mid, max] -- the baseline (min) gets a stronger,
  // slightly opaque stroke so it reads as an axis rather than just another
  // gridline; the other two stay at the plain border color.
  [min, min + (max - min) / 2, max].forEach((tickV, idx) => {
    const ty = y(tickV);
    children.push(
      <line
        key={`tick-line-${idx}`}
        x1={0}
        y1={ty}
        x2={w}
        y2={ty}
        stroke-width="1"
        shape-rendering="crispEdges"
        stroke={idx === 0 ? 'var(--gw-muted)' : 'var(--gw-border)'}
        stroke-opacity={idx === 0 ? '.45' : undefined}
      />,
    );
    // Sits just inside the plot area (4px above its own gridline) rather
    // than in a left-hand gutter, so the chart keeps full-width alignment
    // with the reliability strip above it.
    labels.push(
      <text
        key={`tick-text-${idx}`}
        x={0}
        y={ty - 4}
        text-anchor="start"
        font-size={labelPx}
        fill="var(--gw-muted)"
        {...HALO}
      >
        {opts.yFormat ? opts.yFormat(Math.round(tickV)) : String(Math.round(tickV))}
      </text>,
    );
  });

  if (opts.xStart) {
    labels.push(
      <text
        key="x-start"
        x={0}
        y={h - 4}
        text-anchor="start"
        font-size={labelPx}
        fill="var(--gw-muted)"
        {...HALO}
      >
        {opts.xStart}
      </text>,
    );
  }
  if (opts.xEnd) {
    labels.push(
      <text
        key="x-end"
        x={w}
        y={h - 4}
        text-anchor="end"
        font-size={labelPx}
        fill="var(--gw-muted)"
        {...HALO}
      >
        {opts.xEnd}
      </text>,
    );
  }

  seriesArr.forEach((s, si) => {
    // A null value splits the line into a new polyline rather than
    // interpolating across it or reading as zero -- see status.py's
    // latency_cells() docstring for why a gap is signal, not missing data
    // to smooth over.
    let segment: [number, number][] = [];
    let lastPoint: [number, number] | null = null;
    let segIdx = 0;
    function flushSegment(): void {
      if (segment.length > 1) {
        children.push(
          <polyline
            key={`poly-${si}-${segIdx++}`}
            points={segment.map((p) => p[0].toFixed(2) + ',' + p[1].toFixed(2)).join(' ')}
            fill="none"
            stroke={`var(${s.colorVar})`}
            stroke-width="1.75"
            stroke-linecap="round"
            stroke-linejoin="round"
          />,
        );
      }
      segment = [];
    }
    for (let i = 0; i < s.values.length; i++) {
      const v = s.values[i];
      if (v === null || v === undefined) {
        flushSegment();
        continue;
      }
      // Half-cell offset (matches the reliability strip's own cell math) is
      // what lets this chart share the strip's x-axis: the strip is
      // `count` equal cells, and sample i lines up under the middle of
      // strip cell i.
      const pt: [number, number] = [((i + 0.5) / count) * w, y(v)];
      segment.push(pt);
      lastPoint = pt;
    }
    flushSegment();
    // End-dot on the series' most recent actual value -- ringed in the
    // card's own surface color so it stays legible where two series' lines
    // cross.
    if (lastPoint) {
      children.push(
        <circle
          key={`dot-${si}`}
          cx={lastPoint[0].toFixed(2)}
          cy={lastPoint[1].toFixed(2)}
          r="2.75"
          fill={`var(${s.colorVar})`}
          stroke="var(--gw-card)"
          stroke-width="1.5"
        />,
      );
    }
  });

  children.push(...labels);

  // The scrub overlay's crosshair -- drawn last (so it paints over every
  // series line, matching the end-dot's own on-top treatment above), only
  // while a pointer/keyboard is actively inspecting a point. No transition
  // on either element: appearing/disappearing instantly keeps
  // prefers-reduced-motion a non-issue by construction rather than a second
  // media query needing to cover this too.
  if (activeIndex !== null && count > 0 && activeIndex >= 0 && activeIndex < count) {
    const cx = ((activeIndex + 0.5) / count) * w;
    children.push(
      <line
        key="inspect-crosshair"
        x1={cx.toFixed(2)}
        y1={padTop}
        x2={cx.toFixed(2)}
        y2={h - padBottom}
        stroke="var(--gw-muted)"
        stroke-width="1"
        stroke-dasharray="2,2"
      />,
    );
    seriesArr.forEach((s, si) => {
      const v = s.values[activeIndex];
      if (v === null || v === undefined) return;
      children.push(
        <circle
          key={`inspect-dot-${si}`}
          cx={cx.toFixed(2)}
          cy={y(v).toFixed(2)}
          r="3.5"
          fill={`var(${s.colorVar})`}
          stroke="var(--gw-card)"
          stroke-width="1.5"
        />,
      );
    });
  }

  return (
    <svg
      viewBox={`0 0 ${w} ${h}`}
      width="100%"
      height="100%"
      role="img"
      aria-label={opts.ariaLabel || ''}
    >
      {children}
    </svg>
  );
}

export function LineChart({
  series,
  opts = {},
  inspect,
}: {
  series: ChartSeries[];
  opts?: LineChartOpts;
  /** Controlled scrub state -- index/setter live in whichever panel renders
   * this chart (it also needs the index for its own <Inspector> readout),
   * not in a hook this component owns itself. Omit entirely for a chart
   * with nothing worth inspecting. */
  inspect?: ChartInspect;
}) {
  const wrapRef = useRef<HTMLDivElement>(null);
  const size = useChartSize(wrapRef);

  let count = 0;
  for (const s of series) count = Math.max(count, s.values.length);
  const handlers = inspect ? createScrubHandlers(count, inspect.index, inspect.onIndex) : null;

  function describeIndex(i: number): string {
    if (opts.describeIndex) return opts.describeIndex(i);
    return series
      .map((s, si) => {
        const v = s.values[i];
        const formatted =
          v === null || v === undefined ? '—' : opts.yFormat ? opts.yFormat(v) : String(v);
        return `series ${si + 1}: ${formatted}`;
      })
      .join(', ');
  }

  return (
    <div ref={wrapRef} class={opts.compact ? 'chart chart-compact' : 'chart'}>
      {size && buildSvg(size.w, size.h, series, opts, inspect?.index ?? null)}
      {/* Transparent scrub surface, sized to match the SVG exactly (both
          fill the same measured box) -- see inspect.ts for why the pointer/
          touch/keyboard handling lives there rather than duplicated here.
          touch-action: pan-y lets a vertical drag still scroll the page
          while a horizontal one scrubs. */}
      {size && inspect && handlers && count > 0 && (
        <div
          class="chart-scrub"
          role="slider"
          tabIndex={0}
          aria-valuemin={0}
          aria-valuemax={count - 1}
          aria-valuenow={inspect.index ?? count - 1}
          aria-valuetext={describeIndex(inspect.index ?? count - 1)}
          aria-label={opts.ariaLabel ? `Inspect: ${opts.ariaLabel}` : 'Inspect chart values'}
          onPointerMove={handlers.onPointerMove}
          onPointerDown={handlers.onPointerDown}
          onPointerLeave={handlers.onPointerLeave}
          onKeyDown={handlers.onKeyDown}
        />
      )}
    </div>
  );
}
