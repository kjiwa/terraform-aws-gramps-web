import { useState } from 'preact/hooks';
import type {
  Episode,
  PanelError,
  Reliability as ReliabilityData,
  ReliabilityCell,
  ReliabilityRange,
} from '../../generated/status-payload';
import { fmtDuration, fmtPct, fmtThreshold } from '../../shared/format';
import { LineChart } from '../charts/LineChart';
import { cellIncidents, incidentsText, stripWindow } from '../events';
import { useInspector, useResettableIndex } from '../inspect';
import { availableRanges, defaultSelected, RANGE_ORDER, type RangeKey } from '../ranges';
import { useSeries } from '../series';
import { Card, ErrNote } from '../ui/Card';
import { Inspector } from '../ui/Inspector';
import { LegendPair } from '../ui/LegendPair';
import { RangeSelector } from '../ui/RangeSelector';
import { StatRow } from '../ui/StatRow';
import { ToggleGroup } from '../ui/ToggleGroup';
import { WindowNav } from '../ui/WindowNav';

/**
 * Reliability panel: uptime tiles, reliability strip with scrub inspector
 * (see inspect.ts), and the latency chart. `counting`, `selected` (the
 * detail range), and two independent scrub indices are all card-local UI
 * state.
 */

// Fallback thresholds only, used if a payload somehow lacks them; the
// authoritative values come from reliability.slo_good_threshold/
// slo_warn_threshold so both routes and this page color cells -- and label
// the legend -- identically without hardcoding the same numbers twice.
const SLO_GOOD_FALLBACK = 0.999;
const SLO_WARN_FALLBACK = 0.95;

const COUNTING: [string, string][] = [
  ['all', 'All outages'],
  ['unplanned', 'Unplanned only'],
];

function cellClass(cell: ReliabilityCell, good: number, warn: number): string {
  let band: string;
  if (!cell.samples) band = 'c-gray';
  else if (cell.avg !== null && cell.avg >= good) band = 'c-good';
  else if (cell.avg !== null && cell.avg >= warn) band = 'c-warn';
  else band = 'c-bad';
  return cell.partial ? `${band} c-partial` : band;
}

/**
 * Scrub readout string for a reliability strip cell, used both as the strip's
 * <Inspector> line and as its role="slider" aria-valuetext (see the strip's
 * JSX below).
 */
function cellDetail(cell: ReliabilityCell, r: ReliabilityRange): string {
  const pct = cell.avg === null || cell.avg === undefined ? null : cell.avg * 100;
  let title = `${cell.label} UTC · ${fmtPct(pct)}`;
  // Measured downtime, not a threshold band: scaling by samples/
  // expected_samples reports downtime across the checks that actually
  // reported, rather than extrapolating over minutes CloudWatch has no
  // data for.
  const down =
    cell.avg === null || cell.avg === undefined || !cell.expected_samples
      ? null
      : (1 - cell.avg) * (cell.samples / cell.expected_samples) * r.cell_s;
  if (down !== null && Math.round(down) >= 1) title += ` · ${fmtDuration(down)} down`;
  if (cell.partial) title += ` (in progress, ${cell.samples}/${cell.expected_samples} checks)`;
  return title;
}

// role="img" with a computed aria-label carries the strip's meaning for a
// screen reader as one summary rather than 24-90 unlabelled divs. Reused
// unchanged as the slider's own aria-label (see the strip's JSX below) --
// the strip is interactive (role="slider"), and this provides its
// accessible name.
function stripSummary(cells: ReliabilityCell[], good: number, warn: number): string {
  let goodCount = 0,
    warnCount = 0,
    badCount = 0,
    noDataCount = 0;
  cells.forEach((cell) => {
    if (!cell.samples) noDataCount++;
    else if (cell.avg !== null && cell.avg >= good) goodCount++;
    else if (cell.avg !== null && cell.avg >= warn) warnCount++;
    else badCount++;
  });
  let summary =
    `${cells.length} cells: ${goodCount} at or above ${fmtThreshold(good)}, ` +
    `${warnCount} at or above ${fmtThreshold(warn)}, ${badCount || 'none'} below ${fmtThreshold(warn)}`;
  if (noDataCount) summary += `, ${noDataCount} with no data`;
  return summary;
}

// Index of the last non-null entry in a latency series -- not just the
// "current" p50/p90 value, but which cell it came from, so the caller can
// also look up that cell's server-supplied label.
function lastDefinedIndex(arr: (number | null)[]): number {
  for (let i = arr.length - 1; i >= 0; i--) {
    if (arr[i] !== null && arr[i] !== undefined) return i;
  }
  return -1;
}

function seriesHasData(arr: ({ p50: number | null; p90: number | null } | null)[]): boolean {
  return arr.some(
    (b) =>
      b && ((b.p50 !== null && b.p50 !== undefined) || (b.p90 !== null && b.p90 !== undefined)),
  );
}

function latencyValueText(p50: number | null | undefined, p90: number | null | undefined): string {
  const fmt = (v: number | null | undefined) =>
    v === null || v === undefined ? '—' : Math.round(v) + ' ms';
  return `p50 ${fmt(p50)}, p90 ${fmt(p90)}`;
}

export function Reliability({
  d,
  episodes,
  canPan,
}: {
  d: ReliabilityData | PanelError | undefined;
  episodes?: Episode[] | PanelError;
  canPan?: boolean;
}) {
  const [counting, setCounting] = useState<'all' | 'unplanned'>('all');
  // The panned window's own end, null at rest -- see series.ts's
  // useSeries(). Independent of `counting`: panning the strip has no bearing
  // on which downtime is counted.
  const [end, setEnd] = useState<string | null>(null);

  const ranges: Partial<Record<RangeKey, ReliabilityRange>> =
    (d && !('error' in d) && d.ranges) || {};
  const available = availableRanges((key) => !!ranges[key]);
  const [selected, setSelected] = useState<RangeKey | undefined>(() => defaultSelected(available));
  const series = useSeries<ReliabilityData>('reliability', selected, end);
  // Panning replaces only the strip/latency-chart data for `selected` --
  // the five uptime tiles below keep reading `ranges` (the live payload)
  // directly, unaffected by `r`.
  const seriesR =
    series.data && !('error' in series.data) && selected ? series.data.ranges[selected] : undefined;
  const r = seriesR ?? (selected ? ranges[selected] : undefined);
  const cellCount = r ? r.cells.length : 0;

  // Two independent scrub surfaces, computed before any early return (hook
  // call order must not depend on `d`'s shape) -- resetKey drops each back
  // to resting whenever the array it indexes into could have changed size
  // or content out from under it: a range switch or a pan for the strip, a
  // range switch or a pan for the latency chart.
  const stripInspector = useInspector(cellCount, `${selected}:${end}`);
  const [latencyIndex, setLatencyIndex] = useResettableIndex(`${selected}:${end}`);

  if (!d) return null;
  if ('error' in d) {
    return (
      <Card title="Reliability">
        <ErrNote message={d.error} />
      </Card>
    );
  }

  const good = d.slo_good_threshold ?? SLO_GOOD_FALLBACK;
  const warn = d.slo_warn_threshold ?? SLO_WARN_FALLBACK;
  const decimals = d.decimals;

  const tiles: [string, string, string?][] = RANGE_ORDER.map((key) => {
    const rr = ranges[key];
    // The measurement floor is a property of the probe series, not of
    // which downtime the reader is counting, so it is the same either way.
    const title =
      rr && rr.checks
        ? `±${fmtPct(100 / rr.checks, decimals)} · ${rr.checks.toLocaleString()} checks`
        : undefined;
    // "unplanned" excludes minutes inside a planned=true episode from both
    // sides of the ratio.
    const v = rr ? (counting === 'all' ? rr.uptime : rr.uptime_excl_planned) : null;
    return [fmtPct(v, decimals), key, title];
  });

  const lat = r?.latency;
  const probe = lat?.probe || [];
  const hasLatency = seriesHasData(probe);
  const p50Values = probe.map((b) => (b ? b.p50 : null));
  const p90Values = probe.map((b) => (b ? b.p90 : null));
  const i50 = lastDefinedIndex(p50Values);
  const i90 = lastDefinedIndex(p90Values);
  const restingLatencyIndex = Math.max(i50, i90);

  // At rest (latencyIndex === null) this is exactly the original's
  // lastP50/lastP90/scopeText -- independent per-series lastDefinedIndex,
  // scope from max(i50, i90). Inspecting a specific index instead reads
  // both series at that one index, rendering "—" for a null -- the "one
  // function, called at the resting index when not inspecting" shape the
  // parent plan asks for.
  const effectiveLatencyIndex = latencyIndex ?? restingLatencyIndex;
  const p50AtIdx = effectiveLatencyIndex >= 0 ? p50Values[effectiveLatencyIndex] : null;
  const p90AtIdx = effectiveLatencyIndex >= 0 ? p90Values[effectiveLatencyIndex] : null;
  const scopeAtIdx =
    r && effectiveLatencyIndex >= 0 && r.cells[effectiveLatencyIndex]
      ? `· ${r.cells[effectiveLatencyIndex].label} UTC`
      : null;
  const note = 'Synthetic probe to the home page, not real user traffic.';

  const restingStripIndex = cellCount > 0 ? cellCount - 1 : -1;
  const stripIndex = stripInspector.index ?? restingStripIndex;
  const stripCell = r && stripIndex >= 0 ? r.cells[stripIndex] : undefined;
  const window = r ? stripWindow(r.cells, r.cell_s) : null;
  const named =
    window && stripIndex >= 0 && Array.isArray(episodes)
      ? incidentsText(cellIncidents(window, stripIndex, episodes))
      : '';
  const readout =
    stripCell && r ? [cellDetail(stripCell, r), named].filter(Boolean).join(' · ') : '';

  return (
    <Card title="Reliability">
      <ToggleGroup
        items={COUNTING}
        selected={counting}
        onSelect={(v) => setCounting(v as 'all' | 'unplanned')}
        ariaLabel="Downtime counted"
      />
      {/* aria-live: toggling swaps the numbers in place, which
          aria-pressed on the buttons alone would not announce. */}
      <div aria-live="polite">
        <StatRow items={tiles} />
      </div>

      {/* The selector governs the strip and latency chart below it, not
          the five tiles above -- grouped and hairline-bordered (see
          .range-scope) so that scope reads unambiguously instead of
          looking like it might filter the tile row it sits directly
          beneath. */}
      <div class="range-scope" role="group" aria-label="Uptime detail range">
        <RangeSelector
          available={available}
          selected={selected ?? ''}
          onSelect={(v) => setSelected(v as RangeKey)}
        />
        {canPan && selected && (
          <WindowNav range={selected} end={end} echoedEnd={series.end} onChange={setEnd} />
        )}
        {series.error && <ErrNote message={series.error} />}
        <div class={series.loading ? 'panning' : undefined} aria-busy={series.loading || undefined}>
          <div
            class="strip"
            role="slider"
            tabIndex={0}
            aria-valuemin={0}
            aria-valuemax={Math.max(0, cellCount - 1)}
            aria-valuenow={Math.max(0, stripIndex)}
            aria-valuetext={readout}
            aria-label={r ? stripSummary(r.cells, good, warn) : undefined}
            onPointerMove={stripInspector.onPointerMove}
            onPointerDown={stripInspector.onPointerDown}
            onPointerLeave={stripInspector.onPointerLeave}
            onKeyDown={stripInspector.onKeyDown}
          >
            {r?.cells.map((cell, i) => (
              <div key={i} aria-hidden="true" class={cellClass(cell, good, warn)} />
            ))}
          </div>
          {stripCell && r && <Inspector cls="strip-key">{readout}</Inspector>}
          {/* Built once, not per-range: the legend states percentage
              thresholds, which don't depend on a range's cell width. */}
          <p class="note legend-groups">
            <span class="legend-group">
              <LegendPair cls="c-good" label={`≥${fmtThreshold(good)}`} />
              <LegendPair cls="c-warn" label={`≥${fmtThreshold(warn)}`} />
              <LegendPair cls="c-bad" label={`<${fmtThreshold(warn)}`} />
            </span>
            <span class="legend-group">
              <LegendPair cls="c-gray" label="no data" />
              <LegendPair cls="c-partial" label="in progress" />
            </span>
          </p>
          {hasLatency && r && (
            <>
              <h4>Latency</h4>
              <p class="note">{note}</p>
              <LineChart
                series={[
                  { values: p50Values, colorVar: '--gw-chart-1' },
                  { values: p90Values, colorVar: '--gw-chart-2' },
                ]}
                opts={{
                  min: 0,
                  yFormat: (v) => v + ' ms',
                  xStart: r.cells[0]?.label,
                  xEnd: r.cells[r.cells.length - 1]?.label,
                  ariaLabel: `Latency p50 and p90, milliseconds, over ${selected}`,
                  describeIndex: (i) =>
                    `${latencyValueText(p50Values[i], p90Values[i])}${
                      r.cells[i] ? `, ${r.cells[i].label} UTC` : ''
                    }`,
                }}
                inspect={{ index: latencyIndex, onIndex: setLatencyIndex }}
              />
              <Inspector>
                <LegendPair
                  cls="c-chart1"
                  label={`p50 ${p50AtIdx === null || p50AtIdx === undefined ? '—' : Math.round(p50AtIdx) + ' ms'}`}
                />
                <LegendPair
                  cls="c-chart2"
                  label={`p90 ${p90AtIdx === null || p90AtIdx === undefined ? '—' : Math.round(p90AtIdx) + ' ms'}`}
                />
                {scopeAtIdx && <span>{scopeAtIdx}</span>}
              </Inspector>
            </>
          )}
        </div>
      </div>
    </Card>
  );
}
