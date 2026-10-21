import type { JSX } from 'preact';
import { useRef } from 'preact/hooks';
import { createScrubHandlers, useResettableIndex } from '../inspect';
import { Swatch } from '../ui/Swatch';
import { Tip } from '../ui/Tip';
import { useChartSize } from './useChartSize';

export interface BarSeries {
  name: string;
  /** Swatch class for the tooltip key (see status.css's c-chart* rules). */
  swatch: string;
  colorVar: string;
}

export interface BarBucket {
  /** Tooltip heading and aria-label prefix. */
  title: string;
  /** Short x-axis label; drawn only on a sparse subset of buckets. */
  label: string;
  /** One value per series, bottom of the stack first. */
  values: number[];
}

const BAR_MAX_PX = 24;
const GAP_PX = 2;
const END_RADIUS_PX = 4;
const MAX_TICKS = 4;
const LABEL_SLOT_PX = 120;

/**
 * Whole-number ticks, at most MAX_TICKS of them counting zero: the smallest
 * 1/2/5 x 10^n step that covers `max` in MAX_TICKS - 1 intervals.
 */
export function niceTicks(max: number): number[] {
  const intervals = MAX_TICKS - 1;
  let step = 1;
  for (let pow = 1; Math.ceil(max / step) > intervals; pow *= 10) {
    step = [1, 2, 5].map((m) => m * pow).find((s) => Math.ceil(max / s) <= intervals) ?? 10 * pow;
  }
  const count = Math.max(1, Math.ceil(max / step));
  return Array.from({ length: count + 1 }, (_, i) => i * step);
}

/**
 * Centered on its bar unless that would cross the plot's edge: a label that
 * would overhang the left edge is start-anchored there, one that would
 * overhang the right edge is end-anchored there. `textW` is an estimate.
 */
export function labelPlacement(
  cx: number,
  textW: number,
  left: number,
  right: number,
): { x: number; anchor: 'start' | 'middle' | 'end' } {
  if (cx - textW / 2 < left) return { x: left, anchor: 'start' };
  if (cx + textW / 2 > right) return { x: right, anchor: 'end' };
  return { x: cx, anchor: 'middle' };
}

/** Rounded at the data end (top) only; the baseline end stays square. */
function topRoundedPath(x: number, y: number, w: number, h: number): string {
  const r = Math.min(END_RADIUS_PX, w / 2, h);
  return (
    `M${x},${y + h}V${y + r}A${r},${r} 0 0 1 ${x + r},${y}H${x + w - r}` +
    `A${r},${r} 0 0 1 ${x + w},${y + r}V${y + h}Z`
  );
}

function ariaLabelFor(b: BarBucket, series: BarSeries[]): string {
  const parts = series.map((s, si) => `${s.name} ${b.values[si] ?? 0}`);
  const total = b.values.reduce((a, v) => a + v, 0);
  return `${b.title}: ${parts.join(', ')}, total ${total}`;
}

function place(label: string, cx: number, g: Geometry, right: number) {
  return labelPlacement(cx, label.length * g.labelPx * 0.6, g.gutter, right);
}

function sum(values: number[]): number {
  return values.reduce((a, v) => a + v, 0);
}

interface Geometry {
  labelPx: number;
  ticks: number[];
  yMax: number;
  gutter: number;
  slot: number;
  padTop: number;
  plotH: number;
  base: number;
  barW: number;
}

// Y labels live in a left gutter (unlike LineChart's inside-the-plot
// labels): a bar can reach the top gridline and would otherwise sit on top
// of its own label.
function geometry(w: number, h: number, buckets: BarBucket[]): Geometry {
  const rootFontPx = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16;
  const labelPx = rootFontPx * 0.72;
  const ticks = niceTicks(Math.max(0, ...buckets.map((b) => sum(b.values))));
  const yMax = ticks[ticks.length - 1] ?? 1;
  const gutter = Math.ceil(labelPx * 0.6 * String(yMax).length) + 8;
  const slot = (w - gutter) / buckets.length;
  const padTop = labelPx / 2 + 2;
  const plotH = h - padTop - labelPx - 8;
  return {
    labelPx,
    ticks,
    yMax,
    gutter,
    slot,
    padTop,
    plotH,
    base: padTop + plotH,
    barW: Math.max(1, Math.min(BAR_MAX_PX, slot - GAP_PX)),
  };
}

/** Bottom-first stack; a surface gap sits between segments, taken from the upper one. */
function stackMarks(b: BarBucket, series: BarSeries[], g: Geometry, cx: number): JSX.Element[] {
  const top = b.values.reduce((acc, v, i) => (v > 0 ? i : acc), -1);
  let stacked = 0;
  const marks: JSX.Element[] = [];
  b.values.forEach((v, i) => {
    if (v <= 0) return;
    const lift = stacked > 0 ? GAP_PX : 0;
    const bottom = g.base - (stacked / g.yMax) * g.plotH - lift;
    const height = Math.max(1, (v / g.yMax) * g.plotH - lift);
    const x = cx - g.barW / 2;
    const fill = `var(${series[i]?.colorVar})`;
    marks.push(
      i === top ? (
        <path key={i} d={topRoundedPath(x, bottom - height, g.barW, height)} fill={fill} />
      ) : (
        <rect key={i} x={x} y={bottom - height} width={g.barW} height={height} fill={fill} />
      ),
    );
    stacked += v;
  });
  return marks;
}

export function BarChart({
  series,
  buckets,
  ariaLabel,
  resetKey,
}: {
  series: BarSeries[];
  buckets: BarBucket[];
  ariaLabel: string;
  /** A new value drops the inspected bar, as the other charts' indices do. */
  resetKey: unknown;
}) {
  const wrapRef = useRef<HTMLDivElement>(null);
  const hitRefs = useRef<(SVGRectElement | null)[]>([]);
  const size = useChartSize(wrapRef);
  const [index, setIndex] = useResettableIndex(resetKey);
  const count = buckets.length;

  function moveTo(i: number | null): void {
    setIndex(i);
    if (i !== null) hitRefs.current[i]?.focus();
  }
  const onKeyDown = createScrubHandlers(count, index, moveTo).onKeyDown;

  const g = size && count > 0 ? geometry(size.w, size.h, buckets) : null;
  const active = index === null ? undefined : buckets[index];

  return (
    <div ref={wrapRef} class="chart bar-chart">
      {size && g && (
        <svg
          viewBox={`0 0 ${size.w} ${size.h}`}
          width="100%"
          height="100%"
          role="group"
          aria-label={ariaLabel}
        >
          {g.ticks.map((t, ti) => {
            const ty = g.base - (t / g.yMax) * g.plotH;
            return (
              <g key={t}>
                <line
                  x1={g.gutter}
                  y1={ty}
                  x2={size.w}
                  y2={ty}
                  stroke-width="1"
                  shape-rendering="crispEdges"
                  stroke={ti === 0 ? 'var(--gw-muted)' : 'var(--gw-border)'}
                  stroke-opacity={ti === 0 ? '.45' : undefined}
                />
                <text
                  x={g.gutter - 4}
                  y={ty + g.labelPx * 0.35}
                  text-anchor="end"
                  font-size={g.labelPx}
                  fill="var(--gw-muted)"
                >
                  {t}
                </text>
              </g>
            );
          })}
          {index !== null && (
            <rect
              x={g.gutter + index * g.slot}
              y={g.padTop}
              width={g.slot}
              height={g.plotH}
              fill="var(--gw-border)"
            />
          )}
          {buckets.map((b, i) => {
            const cx = g.gutter + (i + 0.5) * g.slot;
            const labelEvery = Math.max(1, Math.ceil(LABEL_SLOT_PX / g.slot));
            return (
              <g key={b.title}>
                {stackMarks(b, series, g, cx)}
                {i % labelEvery === 0 && (
                  <text
                    x={place(b.label, cx, g, size.w).x}
                    y={size.h - 4}
                    text-anchor={place(b.label, cx, g, size.w).anchor}
                    font-size={g.labelPx}
                    fill="var(--gw-muted)"
                  >
                    {b.label}
                  </text>
                )}
                <rect
                  ref={(el) => {
                    hitRefs.current[i] = el;
                  }}
                  class="bar-hit"
                  x={g.gutter + i * g.slot}
                  y={0}
                  width={g.slot}
                  height={g.base + 2}
                  fill="transparent"
                  tabIndex={i === (index ?? count - 1) ? 0 : -1}
                  role="img"
                  aria-label={ariaLabelFor(b, series)}
                  onPointerEnter={() => setIndex(i)}
                  onPointerDown={() => setIndex(i)}
                  onPointerLeave={(e) => {
                    if (e.pointerType !== 'touch') setIndex(null);
                  }}
                  onFocus={() => setIndex(i)}
                  onBlur={() => setIndex(null)}
                  onKeyDown={onKeyDown}
                />
              </g>
            );
          })}
        </svg>
      )}
      {size && g && active && index !== null && (
        <Tip percent={((g.gutter + (index + 0.5) * g.slot) / size.w) * 100}>
          <p class="tip-title">{active.title}</p>
          {series.map((s, si) => (
            <p key={s.name} class="tip-row">
              <Swatch cls={s.swatch} />
              <strong>{active.values[si] ?? 0}</strong>
              <span>{s.name}</span>
            </p>
          ))}
          <p class="tip-row">
            <strong>{sum(active.values)}</strong>
            <span>total</span>
          </p>
        </Tip>
      )}
    </div>
  );
}
