import type { ComponentChildren } from 'preact';
import { useState } from 'preact/hooks';
import type { Host as HostData, HostMetrics, PanelError } from '../../generated/status-payload';
import { fmtDate, fmtDuration, fmtPct } from '../../shared/format';
import type { ChartSeries } from '../charts/LineChart';
import { LineChart } from '../charts/LineChart';
import { useResettableIndex } from '../inspect';
import {
  availableRanges,
  defaultSelected,
  relativeLabel,
  windowAxisLabels,
  type RangeKey,
} from '../ranges';
import { useSeries } from '../series';
import { Card, ErrNote } from '../ui/Card';
import { Inspector } from '../ui/Inspector';
import { Kv } from '../ui/Kv';
import { LegendPair } from '../ui/LegendPair';
import { RangeSelector } from '../ui/RangeSelector';
import { WindowNav } from '../ui/WindowNav';

/**
 * m (host_metrics) is a distinct, independently-gated payload merged in here
 * for the CPU/memory chart rather than rendered as its own card, since CPU
 * is a property of the host this card already describes -- see Storage.tsx,
 * which shares the same `m` for its disk-used meter.
 */
function capacityText(cap: { desired: number; min: number; max: number }): string {
  if (cap.min === cap.max) return String(cap.desired);
  return `${cap.desired} (${cap.min}–${cap.max})`;
}

export function Host({
  d,
  m,
  canPan,
}: {
  d: HostData | PanelError | undefined;
  m: HostMetrics | PanelError | undefined;
  canPan?: boolean;
}) {
  // host_metrics drops a failed series entirely rather than zeroing it --
  // CPU and memory fail independently, so whichever of the two came back
  // carries the full CHART_RANGES key set, and either one's own `ranges`
  // object is enough to know what's available.
  const metricsOk = !!(m && !('error' in m));
  const hostRanges: Partial<Record<RangeKey, (number | null)[]>> =
    (metricsOk &&
      m &&
      !('error' in m) &&
      ((m.cpu_percent && m.cpu_percent.ranges) ||
        (m.mem_used_percent && m.mem_used_percent.ranges))) ||
    {};
  const hostAvailable = availableRanges((key) => hostRanges[key] !== undefined);
  const [hostSelected, setHostSelected] = useState<RangeKey | undefined>(() =>
    defaultSelected(hostAvailable),
  );
  // /_status/series?panel=host_metrics also feeds Storage's own chart (a
  // separate call there, with its own range/end -- the two surfaces pan
  // independently even though they share this one endpoint shape).
  const [hostEnd, setHostEnd] = useState<string | null>(null);
  const hostSeries = useSeries<HostMetrics>('host_metrics', hostSelected, hostEnd);
  const [hostIndex, setHostIndex] = useResettableIndex(`${hostSelected}:${hostEnd}`);

  if (!d) return null;
  if ('error' in d) {
    return (
      <Card title="Host">
        <ErrNote message={d.error} />
      </Card>
    );
  }
  const i = d.instance;
  if (!i) {
    return (
      <Card title="Host">
        <p class="note">No running instance (environment asleep?).</p>
      </Card>
    );
  }

  const showChart = metricsOk && hostAvailable.length > 0;
  const key = hostSelected;
  // Panning replaces only these two arrays -- current (below) and every
  // other Host field keep reading the live `m`/`d` props, per the parent
  // plan's "Panel wiring" rule.
  const seriesM = hostSeries.data && !('error' in hostSeries.data) ? hostSeries.data : undefined;
  const cpuAtRange = key
    ? (seriesM?.cpu_percent?.ranges[key] ??
      (m && !('error' in m) ? m.cpu_percent?.ranges[key] : undefined))
    : undefined;
  const memAtRange = key
    ? (seriesM?.mem_used_percent?.ranges[key] ??
      (m && !('error' in m) ? m.mem_used_percent?.ranges[key] : undefined))
    : undefined;
  const rangeCount = Math.max(cpuAtRange?.length ?? 0, memAtRange?.length ?? 0);
  const chartSeries: ChartSeries[] = [];
  if (showChart && m && !('error' in m) && key) {
    if (m.cpu_percent && cpuAtRange)
      chartSeries.push({ values: cpuAtRange, colorVar: '--gw-chart-1' });
    if (m.mem_used_percent && memAtRange) {
      chartSeries.push({ values: memAtRange, colorVar: '--gw-chart-2' });
    }
  }

  // At rest (hostIndex === null), this is exactly the original's current-
  // reading key: CPU/memory's own `current` scalar, read off the 24h
  // query's freshest datapoint regardless of which range is selected (see
  // host_metrics()'s docstring in status.py) -- deliberately not "the
  // range's own last bucket," which can lag current by up to that range's
  // own period. Inspecting a specific index instead reads that range's
  // ranges[key][i] directly, per the parent plan -- the two are genuinely
  // different data (a live scalar vs. a historical per-bucket array), so
  // this stays one function with one branch rather than pretending they're
  // interchangeable.
  function keyItems(): ComponentChildren[] {
    if (!showChart || !m || 'error' in m || !key) return [];
    if (hostIndex === null) {
      const items: ComponentChildren[] = [];
      // 1 decimal, not fmtPct's 2-decimal default: a gauge sampled at
      // 5-minute granularity has no business claiming "1.30%" precision.
      if (m.cpu_percent) {
        items.push(
          <LegendPair key="cpu" cls="c-chart1" label={`CPU ${fmtPct(m.cpu_percent.current, 1)}`} />,
        );
      }
      if (m.mem_used_percent) {
        items.push(
          <LegendPair
            key="mem"
            cls="c-chart2"
            label={`memory ${fmtPct(m.mem_used_percent.current, 1)}`}
          />,
        );
      }
      return items;
    }
    const cpuV = cpuAtRange?.[hostIndex];
    const memV = memAtRange?.[hostIndex];
    const items: ComponentChildren[] = [];
    if (m.cpu_percent) {
      items.push(<LegendPair key="cpu" cls="c-chart1" label={`CPU ${fmtPct(cpuV, 1)}`} />);
    }
    if (m.mem_used_percent) {
      items.push(<LegendPair key="mem" cls="c-chart2" label={`memory ${fmtPct(memV, 1)}`} />);
    }
    items.push(
      <span key="when">
        {relativeLabel(key, hostIndex, rangeCount, hostEnd !== null ? hostSeries.end : null)}
      </span>,
    );
    return items;
  }

  function describeIndex(i2: number): string {
    if (!key) return '';
    const cpuV = cpuAtRange?.[i2];
    const memV = memAtRange?.[i2];
    return `CPU ${fmtPct(cpuV, 1)}, memory ${fmtPct(memV, 1)}, ${relativeLabel(key, i2, rangeCount, hostEnd !== null ? hostSeries.end : null)}`;
  }

  return (
    <Card title="Host">
      <div class="subgrid">
        <div>
          <h4>Instance</h4>
          <Kv
            pairs={[
              ['ID', i.id],
              ['Type', i.type],
              ['Arch', i.architecture],
              ['AZ', i.az],
              ['Lifecycle', i.lifecycle],
              ['Launched', fmtDate(i.launch_time)],
              ['Uptime', fmtDuration(i.uptime_s)],
              ['Capacity', d.capacity ? capacityText(d.capacity) : null],
            ]}
          />
        </div>
        {showChart && (
          <div>
            <h4>CPU & memory</h4>
            <RangeSelector
              available={hostAvailable}
              selected={hostSelected ?? ''}
              onSelect={(v) => setHostSelected(v as RangeKey)}
            />
            {canPan && key && (
              <WindowNav
                range={key}
                end={hostEnd}
                echoedEnd={hostSeries.end}
                onChange={setHostEnd}
              />
            )}
            {hostSeries.error && <ErrNote message={hostSeries.error} />}
            {/* host_metrics carries no timestamps -- relative labels are
                the honest axis here, not clock times synthesized from a
                bucket count that duplicates a server-side contract. */}
            <div
              class={hostSeries.loading ? 'panning' : undefined}
              aria-busy={hostSeries.loading || undefined}
            >
              {chartSeries.length > 0 && (
                <>
                  <LineChart
                    series={chartSeries}
                    opts={{
                      min: 0,
                      max: 100,
                      yFormat: (v) => v + '%',
                      ...windowAxisLabels(key, hostEnd !== null ? hostSeries.end : null),
                      ariaLabel: `CPU and memory percent used, last ${key}`,
                      describeIndex,
                    }}
                    inspect={{ index: hostIndex, onIndex: setHostIndex }}
                  />
                  <Inspector>{keyItems()}</Inspector>
                </>
              )}
            </div>
          </div>
        )}
      </div>
      {/* A whole-call failure is surfaced the same way every other panel's
          top-level error is -- it must not vanish silently just because
          it's merged into a card that also has identity rows to show. */}
      {m && 'error' in m ? (
        <ErrNote message={m.error} />
      ) : (
        <>
          {m?.cpu_percent_error && <ErrNote message={m.cpu_percent_error} />}
          {m?.mem_used_percent_error && <ErrNote message={m.mem_used_percent_error} />}
        </>
      )}
    </Card>
  );
}
