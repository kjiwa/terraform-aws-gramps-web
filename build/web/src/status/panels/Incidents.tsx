import type { ComponentChildren } from 'preact';
import { useState } from 'preact/hooks';
import type {
  Episode,
  InstanceRef,
  Interruption,
  PanelError,
} from '../../generated/status-payload';
import { fmtDate, fmtDay, fmtDuration, fmtPct, fmtStamp } from '../../shared/format';
import { BarChart, type BarBucket, type BarSeries } from '../charts/BarChart';
import { CAUSE_CLASSES } from '../causes';
import { cellLabel, incidentCounts } from '../events';
import { DEFAULT_RANGE, gridFor, RANGE_ORDER, type RangeKey } from '../ranges';
import {
  episodesIn,
  hasSpotActivity,
  isSpotEpisode,
  median,
  percentile,
  poolTable,
  recoverySplit,
  spotData,
  summarize,
  type PoolRow,
  type RecoverySplit,
  type SpotData,
} from '../spot';
import { Card, ErrNote } from '../ui/Card';
import { LegendPair } from '../ui/LegendPair';
import { RangeSelector } from '../ui/RangeSelector';
import { StatRow } from '../ui/StatRow';
import { WindowNav } from '../ui/WindowNav';

/**
 * Incidents and the Spot reclaims subsection, on the page's own time grid
 * (ranges.ts's RANGE_CELLS). The payload holds a year, so the range and its
 * panned end are card-local, client-side state: no refetch. `operator` adds
 * the views that need instance details the public route withholds.
 */

const HISTORY_DAYS = 365;

const SERIES: BarSeries[] = CAUSE_CLASSES.map((c) => ({
  name: c.label,
  swatch: c.swatch,
  colorVar: c.colorVar,
}));

interface IncidentStats {
  count: number;
  totalDown: number;
  unplannedDown: number;
  median: number | null;
  p90: number | null;
  causeMix: string;
  instanceTypeCount: number;
}

// Client-side aggregation only -- no server change, no new disclosure.
// duration_s/cause/planned are already in the public allowlist, so every
// number below is derived entirely from data the public route already
// ships; new_instance.type is not, so it is naturally absent there --
// guarded on its own presence below, not branched on which route this
// render came from.
function incidentStats(d: Episode[]): IncidentStats {
  let totalDown = 0;
  let unplannedDown = 0;
  const durations: number[] = [];
  const causeCounts: Record<string, number> = {};
  const instanceTypes: Record<string, boolean> = {};
  d.forEach((ep) => {
    const dur = ep.duration_s || 0;
    totalDown += dur;
    if (!ep.planned) unplannedDown += dur;
    durations.push(dur);
    const cause = ep.cause || 'unknown';
    causeCounts[cause] = (causeCounts[cause] || 0) + 1;
    const type = ep.new_instance && ep.new_instance.type;
    if (type) instanceTypes[type] = true;
  });
  const causeMix = Object.keys(causeCounts)
    .sort((a, b) => (causeCounts[b] ?? 0) - (causeCounts[a] ?? 0))
    .map((cause) => `${causeCounts[cause]} ${cause}`)
    .join(' · ');
  return {
    count: d.length,
    totalDown,
    unplannedDown,
    median: median(durations),
    p90: percentile(durations, 0.9),
    causeMix,
    instanceTypeCount: Object.keys(instanceTypes).length,
  };
}

// old.type -> new.type · az for a spot reclaim; new.type · az otherwise.
// Called only where new_instance is already known present. Each token is
// kept whole (types wrap only between tokens, the az never splits).
function instanceCell(ep: Episode) {
  const n = ep.new_instance as InstanceRef;
  const type = ep.old_instance ? `${ep.old_instance.type} → ${n.type}` : n.type;
  return (
    <>
      {type} · <span class="nowrap">{n.az}</span>
    </>
  );
}

function SplitBar({ split }: { split: RecoverySplit }) {
  const total = split.capacityWaitS + split.bootToServeS;
  const capacity = total > 0 ? split.capacityWaitS / total : 0.5;
  const pct = (f: number) => `${Math.round(f * 100)}%`;
  const capacityText = `Capacity wait ${fmtDuration(split.capacityWaitS)} (${pct(capacity)})`;
  const bootText = `Boot to serve ${fmtDuration(split.bootToServeS)} (${pct(1 - capacity)})`;
  return (
    <>
      <h4>Recovery split</h4>
      <div class="split-bar" role="img" aria-label={`${capacityText}, ${bootText}`}>
        <div style={{ flex: capacity, background: 'var(--gw-chart-2)' }} />
        <div style={{ flex: 1 - capacity, background: 'var(--gw-chart-2-tint)' }} />
      </div>
      <p class="note legend-groups">
        <LegendPair cls="c-chart2" label={capacityText} />
        <LegendPair cls="c-chart2-tint" label={bootText} />
      </p>
      <p class="note">{`Medians over ${split.count} outages with recovery timing.`}</p>
    </>
  );
}

function PoolTable({ rows }: { rows: PoolRow[] }) {
  return (
    <details>
      <summary>Pools</summary>
      <div class="table-scroll">
        <table class="tbl dense">
          <thead>
            <tr>
              <th>Pool</th>
              <th>Reclaims</th>
              <th>Median lifetime</th>
              <th>Last reclaim (UTC)</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={`${r.type}/${r.az}`}>
                <td class="wrap">
                  <div>{r.type}</div>
                  {r.az && <div class="sub nowrap">{r.az}</div>}
                </td>
                <td>{r.reclaims}</td>
                <td>{fmtDuration(r.medianLifetimeS)}</td>
                <td class="nowrap" title={fmtDate(r.last)}>
                  {fmtDay(r.last)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </details>
  );
}

function SpotSection({
  data,
  window,
  operator,
}: {
  data: SpotData;
  window: { startMs: number; endMs: number };
  operator?: boolean;
}) {
  const s = summarize(data, window);
  const outages = episodesIn(data, window).filter(isSpotEpisode);
  const split = recoverySplit(outages).split;
  const items: [ComponentChildren, string, string?][] = [
    [String(s.reclaims), 'Reclaim warnings', 'Spot interruption warnings in range'],
    [String(s.outages), 'Caused an outage', 'Spot-reclaim episodes in range'],
    [
      s.downtimeShare === null ? '—' : fmtPct(s.downtimeShare, 1),
      'Share of downtime',
      'Spot-reclaim downtime over the downtime of every episode in range',
    ],
  ];
  return (
    <>
      <h4>Spot reclaims</h4>
      <div aria-live="polite">
        <StatRow items={items} />
      </div>
      {operator && split && <SplitBar split={split} />}
      {operator && outages.length > 0 && <PoolTable rows={poolTable(outages)} />}
    </>
  );
}

function IncidentTable({ episodes }: { episodes: Episode[] }) {
  // Dataset-level, not per-row: absent everywhere on the public route (its
  // allowlist drops both fields), present everywhere on the operator route
  // -- the same "the data decides" pattern incidentStats() uses above for
  // the instance-types tile.
  const hasEnded = episodes.some((ep) => ep.ended);
  const hasInstance = episodes.some((ep) => ep.new_instance);
  const summaryText = `${episodes.length} incident${episodes.length === 1 ? '' : 's'} · most recent ${fmtDate(episodes[0]?.started)}`;
  return (
    <details>
      <summary>{summaryText}</summary>
      <div class="table-scroll">
        <table class="tbl">
          <thead>
            <tr>
              <th>Started (UTC)</th>
              {hasEnded && <th>Ended (UTC)</th>}
              <th>Duration</th>
              <th>Cause</th>
              <th>Planned</th>
              {hasInstance && <th>Instance</th>}
            </tr>
          </thead>
          <tbody>
            {episodes.map((ep, i) => (
              <tr key={i}>
                <td class="nowrap" title={fmtDate(ep.started)}>
                  {fmtStamp(ep.started)}
                </td>
                {hasEnded && (
                  <td class="nowrap" title={fmtDate(ep.ended)}>
                    {fmtStamp(ep.ended)}
                  </td>
                )}
                <td>{fmtDuration(ep.duration_s)}</td>
                <td class="nowrap">{ep.cause || 'unknown'}</td>
                <td>{ep.planned ? <span class="badge">planned</span> : '—'}</td>
                {hasInstance && <td>{ep.new_instance ? instanceCell(ep) : '—'}</td>}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </details>
  );
}

function IncidentsBody({
  d,
  interruptions,
  spotEnabled,
  operator,
}: {
  d: Episode[];
  interruptions: Interruption[] | PanelError | undefined;
  spotEnabled: boolean;
  operator?: boolean;
}) {
  const [range, setRange] = useState<RangeKey>(DEFAULT_RANGE);
  const [end, setEnd] = useState<string | null>(null);
  // Read on every render, not memoized: a page left open keeps its window.
  // eslint-disable-next-line react-hooks/purity
  const nowMs = Date.now();

  const grid = gridFor(range, end === null ? nowMs : Date.parse(end));
  const data = spotData(d, interruptions);
  const episodes = episodesIn(data, grid);
  const s = incidentStats(episodes);
  const stats: [string, string, string?, string?][] = [
    [String(s.count), 'incidents'],
    [fmtDuration(s.totalDown), 'total downtime'],
    [fmtDuration(s.unplannedDown), 'unplanned'],
    [fmtDuration(s.median), 'median recovery', undefined, `p90 ${fmtDuration(s.p90)}`],
  ];
  // Distinct instance types is operator-only -- it only renders when at
  // least one episode actually carried new_instance.type, which is exactly
  // the signal for "am I looking at the authenticated payload."
  if (s.instanceTypeCount > 0) stats.push([String(s.instanceTypeCount), 'instance types']);

  const buckets: BarBucket[] = incidentCounts(grid, episodes).map((values, i) => ({
    ...cellLabel(grid, i),
    values,
  }));
  const present = CAUSE_CLASSES.filter((_, i) => buckets.some((b) => (b.values[i] ?? 0) > 0));
  const showSpot = spotEnabled || hasSpotActivity(data);

  return (
    <>
      <div class="range-scope" role="group" aria-label="Incident range">
        <RangeSelector
          available={[...RANGE_ORDER]}
          selected={range}
          onSelect={(v) => setRange(v as RangeKey)}
        />
        <WindowNav
          range={range}
          end={end}
          echoedEnd={end}
          onChange={setEnd}
          maxAgeDays={HISTORY_DAYS}
        />
      </div>
      <div aria-live="polite">
        <StatRow items={stats} />
      </div>
      {s.causeMix && <p class="note">{`Causes: ${s.causeMix}`}</p>}
      {episodes.length === 0 ? (
        <p class="note">No incidents in this window.</p>
      ) : (
        <>
          <BarChart
            series={SERIES}
            buckets={buckets}
            ariaLabel={`Incidents per cell over ${range}, by cause`}
            resetKey={`${range}:${end}`}
          />
          <p class="note legend-groups">
            {present.map((c) => (
              <LegendPair key={c.id} cls={c.swatch} label={c.label} />
            ))}
          </p>
          <IncidentTable episodes={episodes} />
        </>
      )}
      {showSpot &&
        (Array.isArray(interruptions) || interruptions === undefined ? (
          <SpotSection data={data} window={grid} operator={operator} />
        ) : (
          <ErrNote message={interruptions.error} />
        ))}
    </>
  );
}

export function Incidents({
  d,
  interruptions,
  spotEnabled,
  operator,
}: {
  d: Episode[] | PanelError | undefined;
  interruptions: Interruption[] | PanelError | undefined;
  spotEnabled: boolean;
  operator?: boolean;
}) {
  if (!d) return null;
  if ('error' in d) {
    return (
      <Card title="Incidents">
        <ErrNote message={d.error} />
      </Card>
    );
  }
  if (!Array.isArray(d) || d.length === 0) {
    return (
      <Card title="Incidents">
        <p class="note">No incidents in the last year.</p>
      </Card>
    );
  }
  return (
    <Card title="Incidents">
      <IncidentsBody
        d={d}
        interruptions={interruptions}
        spotEnabled={spotEnabled}
        operator={operator}
      />
    </Card>
  );
}
