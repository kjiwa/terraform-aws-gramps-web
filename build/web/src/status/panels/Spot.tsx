import type { ComponentChildren } from 'preact';
import { useState } from 'preact/hooks';
import type { Episode, Interruption, PanelError } from '../../generated/status-payload';
import { fmtDate, fmtDay, fmtDuration, fmtPct } from '../../shared/format';
import { BarChart, type BarBucket, type BarSeries } from '../charts/BarChart';
import {
  episodesIn,
  hasSpotActivity,
  isSpotEpisode,
  poolTable,
  recoverySplit,
  SPLIT_MIN_EPISODES,
  SPOT_DEFAULT_RANGE,
  SPOT_RANGES,
  spotData,
  summarize,
  weeklyBuckets,
  type PoolRow,
  type RecoverySplit,
  type SpotRange,
  type SpotSummary,
  type WeekBucket,
} from '../spot';
import { Card, ErrNote } from '../ui/Card';
import { LegendPair } from '../ui/LegendPair';
import { RangeSelector } from '../ui/RangeSelector';
import { StatRow } from '../ui/StatRow';

/**
 * Spot reclaims: warnings against outages, from data both payload routes
 * already carry. `operator` adds the two views that need instance details
 * the public route withholds (recovery split, pool table). `range` and its
 * clock reading are card-local, client-side state: the payload holds a year.
 */

const RANGE_PHRASE: Record<SpotRange, string> = {
  '30d': '30 days',
  '90d': '90 days',
  '1y': 'year',
};

// Outage first: it is the series the panel is about, and the Spot-reclaim
// orange the events lane uses. Absorbed is a non-event, so it is the neutral
// muted ink, not a series hue.
const SERIES: BarSeries[] = [
  { name: 'Caused an outage', swatch: 'c-chart2', colorVar: '--gw-chart-2' },
  { name: 'Absorbed', swatch: 'c-muted', colorVar: '--gw-muted' },
];

function tiles(s: SpotSummary): [ComponentChildren, string, string?, string?][] {
  return [
    [String(s.reclaims), 'Reclaims', 'Spot interruption warnings in range'],
    [String(s.outages), 'Caused an outage', 'Spot-reclaim episodes in range'],
    [
      String(s.absorbed),
      'Absorbed',
      'Warnings minus outage episodes, per week, floored at zero (approximate)',
    ],
    [fmtDuration(s.downtimeS), 'Downtime', 'Total duration of the spot-reclaim episodes'],
    [
      s.downtimeShare === null ? '—' : fmtPct(s.downtimeShare, 1),
      'Share of downtime',
      'Spot-reclaim downtime over the downtime of every episode in range',
    ],
    [
      fmtDuration(s.medianS),
      'Median recovery',
      'Duration of a spot-reclaim episode',
      `p90 ${fmtDuration(s.p90S)}`,
    ],
  ];
}

function weekBuckets(weeks: WeekBucket[]): BarBucket[] {
  return weeks.map((w) => ({
    title: `Week of ${w.start.slice(0, 10)}`,
    label: w.start.slice(0, 10),
    values: [w.outages, w.absorbed],
  }));
}

function WeekTable({ buckets }: { buckets: BarBucket[] }) {
  return (
    <details>
      <summary>Show data table</summary>
      <div class="table-scroll">
        <table class="tbl">
          <thead>
            <tr>
              <th>Week of (UTC)</th>
              <th>Caused an outage</th>
              <th>Absorbed</th>
              <th>Total</th>
            </tr>
          </thead>
          <tbody>
            {buckets.map((b) => (
              <tr key={b.title}>
                <td class="nowrap">{b.label}</td>
                <td>{b.values[0]}</td>
                <td>{b.values[1]}</td>
                <td>{(b.values[0] ?? 0) + (b.values[1] ?? 0)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </details>
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

function RecoverySplitView({ episodes }: { episodes: Episode[] }) {
  const { timed, split } = recoverySplit(episodes);
  return (
    <>
      <h4>Recovery split</h4>
      {split ? (
        <SplitBar split={split} />
      ) : (
        <p class="note">
          {`Recovery timing is recorded for ${timed} of ${episodes.length} reclaim outages so far; ` +
            `the split appears at ${SPLIT_MIN_EPISODES}. It exists only for outages recorded since timing was added.`}
        </p>
      )}
    </>
  );
}

function PoolTable({ rows }: { rows: PoolRow[] }) {
  return (
    <>
      <h4>Pools</h4>
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
    </>
  );
}

export function Spot({
  incidents,
  interruptions,
  spotEnabled,
  operator,
}: {
  incidents: Episode[] | PanelError | undefined;
  interruptions: Interruption[] | PanelError | undefined;
  spotEnabled: boolean;
  operator?: boolean;
}) {
  const [range, setRange] = useState<SpotRange>(SPOT_DEFAULT_RANGE);
  // Read on every render, not memoized: a page left open keeps its window.
  // eslint-disable-next-line react-hooks/purity
  const nowMs = Date.now();

  const failed = [incidents, interruptions].find((d) => d && !Array.isArray(d));
  const data = spotData(incidents, interruptions);
  if (!spotEnabled && !hasSpotActivity(data)) return null;
  if (failed && 'error' in failed) {
    return (
      <Card title="Spot reclaims">
        <ErrNote message={failed.error} />
      </Card>
    );
  }

  const summary = summarize(data, range, nowMs);
  const outages = episodesIn(data, range, nowMs).filter(isSpotEpisode);
  const empty = summary.reclaims === 0 && summary.outages === 0;
  const buckets = weekBuckets(weeklyBuckets(data, range, nowMs));

  return (
    <Card title="Spot reclaims">
      <RangeSelector
        available={SPOT_RANGES}
        selected={range}
        onSelect={(v) => setRange(v as SpotRange)}
      />
      <div aria-live="polite">
        <StatRow items={tiles(summary)} />
      </div>
      {empty ? (
        <p class="note">{`No reclaims in the last ${RANGE_PHRASE[range]}.`}</p>
      ) : (
        <>
          <h4>Reclaims per week</h4>
          <BarChart
            series={SERIES}
            buckets={buckets}
            ariaLabel={`Spot reclaims per week over ${range}: outages and absorbed warnings`}
            resetKey={range}
          />
          <p class="note legend-groups">
            {SERIES.map((s) => (
              <LegendPair key={s.name} cls={s.swatch} label={s.name} />
            ))}
          </p>
          <p class="note">
            Absorbed is approximate: each week&rsquo;s warnings beyond its outage episodes, floored
            at zero.
          </p>
          <WeekTable buckets={buckets} />
          {operator && outages.length > 0 && (
            <>
              <RecoverySplitView episodes={outages} />
              <PoolTable rows={poolTable(outages)} />
            </>
          )}
        </>
      )}
    </Card>
  );
}
