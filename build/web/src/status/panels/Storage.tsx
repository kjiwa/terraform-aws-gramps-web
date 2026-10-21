import type { ComponentChildren } from 'preact';
import { useState } from 'preact/hooks';
import type {
  HostMetrics,
  HostMetricSeries,
  PanelError,
  Storage as StorageData,
} from '../../generated/status-payload';
import { fmtBool, fmtBytes, fmtPct } from '../../shared/format';
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
import { Bar } from '../ui/Bar';
import { Card, ErrNote } from '../ui/Card';
import { Inspector } from '../ui/Inspector';
import { Kv, type KvValue } from '../ui/Kv';
import { LegendPair } from '../ui/LegendPair';
import { RangeSelector } from '../ui/RangeSelector';
import { WindowNav } from '../ui/WindowNav';

type Volume = NonNullable<StorageData['volumes']>[number];

interface DiskMeter {
  usedPct: number;
  sizeGb: number;
  usedGb: number;
  error?: string;
}

// m (host_metrics) is shared with Host.tsx -- merged in here only for the
// disk-used meter, since disk belongs to the volume this card describes.
// Independent of the volume/media rows above: a whole-call host_metrics
// failure (or the data volume itself lacking a known size) simply omits the
// meter, matching the original's single combined guard.
function diskMeter(
  m: HostMetrics | PanelError | undefined,
  sizeGb: number | null,
): DiskMeter | null {
  if (!m || 'error' in m) return null;
  const usedPct = m.disk_used_percent?.current;
  if (usedPct === null || usedPct === undefined || !sizeGb) return null;
  return { usedPct, sizeGb, usedGb: sizeGb * (usedPct / 100), error: m.disk_used_percent_error };
}

/** "<used> of <total> (<pct>%)" for one volume's byte pair -- null if that
 * role hasn't published yet (per-metric error isolation, or the AMI hasn't
 * rolled since VOLUME_METRICS_ENABLED went on). The percent this derives is
 * against the filesystem's own measured size, not the EC2 volume's
 * allocated size_gb -- the two differ (ext4 overhead). */
function usedRow(m: HostMetrics | PanelError | undefined, role: 'data' | 'root'): string | null {
  if (!m || 'error' in m) return null;
  const used = role === 'data' ? m.disk_used_bytes_data?.current : m.disk_used_bytes_root?.current;
  const total =
    role === 'data' ? m.disk_total_bytes_data?.current : m.disk_total_bytes_root?.current;
  if (used === null || used === undefined || !total) return null;
  return `${fmtBytes(used)} of ${fmtBytes(total)} (${((used / total) * 100).toFixed(1)}%)`;
}

/** Which path to render: chosen by what the payload contains, never by a
 * flag. Either role publishing is enough (per-metric error isolation means one
 * can fail independently of the other). */
function hasByteSeries(m: HostMetrics | PanelError | undefined): boolean {
  if (!m || 'error' in m) return false;
  return m.disk_used_bytes_data?.current != null || m.disk_used_bytes_root?.current != null;
}

/** Per-cell used/total, never used/current-total: DiskTotalBytes steps when
 * the volume is resized, and dividing every cell by today's capacity would
 * restate history at a size that volume never had. Exported for direct unit
 * coverage of the resize-step and missing-total cases -- see
 * status-storage.test.ts. */
export function pctRange(
  used: HostMetricSeries | undefined,
  total: HostMetricSeries | undefined,
  key: RangeKey,
): (number | null)[] | undefined {
  const u = used?.ranges[key];
  const t = total?.ranges[key];
  if (!u || !t) return undefined;
  return u.map((v, i) => {
    const cap = t[i];
    return v == null || cap == null || cap <= 0 ? null : (v / cap) * 100;
  });
}

export function pctCurrent(
  used: HostMetricSeries | undefined,
  total: HostMetricSeries | undefined,
): number | null {
  const u = used?.current;
  const t = total?.current;
  return u == null || t == null || t <= 0 ? null : (u / t) * 100;
}

function VolumeColumn({
  title,
  v,
  used,
}: {
  title: string;
  v: Volume | undefined;
  used: string | null;
}) {
  const pairs: [string, KvValue][] = [
    ['ID', v ? v.id : null],
    ['Size', v ? `${v.size_gb} GiB` : null],
    ['Type', v ? v.type : null],
    ['IOPS', v ? v.iops : null],
    ['Encrypted', v ? fmtBool(v.encrypted) : null],
    ['State', v ? v.state : null],
  ];
  if (used) pairs.push(['Used', used]);
  return (
    <div>
      <h4>{title}</h4>
      <Kv pairs={pairs} />
    </div>
  );
}

/**
 * Covers a second (root) volume and, on the byte path, exact disk usage in
 * place of a fabricated-precision percent. Wired exactly as Host.tsx's
 * CPU/memory chart: useResettableIndex, relativeLabel as the readout's third
 * item, describeIndex for the overlay's aria-valuetext.
 */
export function Storage({
  d,
  m,
  canPan,
}: {
  d: StorageData | PanelError | undefined;
  m: HostMetrics | PanelError | undefined;
  canPan?: boolean;
}) {
  const byBytes = hasByteSeries(m);
  // A range is renderable only if used AND total both have it -- pctRange
  // returns undefined otherwise, which would otherwise plot a partial or
  // divide-by-nothing chart.
  const usedRanges: HostMetricSeries['ranges'] | undefined =
    (byBytes &&
      m &&
      !('error' in m) &&
      ((m.disk_used_bytes_data && m.disk_used_bytes_data.ranges) ||
        (m.disk_used_bytes_root && m.disk_used_bytes_root.ranges))) ||
    undefined;
  const totalRanges: HostMetricSeries['ranges'] | undefined =
    (byBytes &&
      m &&
      !('error' in m) &&
      ((m.disk_total_bytes_data && m.disk_total_bytes_data.ranges) ||
        (m.disk_total_bytes_root && m.disk_total_bytes_root.ranges))) ||
    undefined;
  const diskAvailable = availableRanges(
    (key) => usedRanges?.[key] !== undefined && totalRanges?.[key] !== undefined,
  );
  const [diskSelected, setDiskSelected] = useState<RangeKey | undefined>(() =>
    defaultSelected(diskAvailable),
  );
  // A separate GET /_status/series?panel=host_metrics call from Host's own
  // (see that file's comment) -- same endpoint shape, independent range/
  // end, since Storage's chart pans on its own schedule.
  const [diskEnd, setDiskEnd] = useState<string | null>(null);
  const diskSeries = useSeries<HostMetrics>('host_metrics', diskSelected, diskEnd);
  const [diskIndex, setDiskIndex] = useResettableIndex(`${diskSelected}:${diskEnd}`);

  if (!d) return null;
  if ('error' in d) {
    return (
      <Card title="Storage">
        <ErrNote message={d.error} />
      </Card>
    );
  }

  const dataVolume = d.volumes?.find((v) => v.role === 'data');
  const rootVolume = d.volumes?.find((v) => v.role === 'root');
  const hasObjectCount = d.bucket_object_count !== null && d.bucket_object_count !== undefined;
  // Percent-path meter only -- the byte path's own chart replaces it (see
  // showChart below). Full-width, below the subgrid, matching Cost's own
  // note+bar budget meter.
  const meter = !byBytes ? diskMeter(m, dataVolume?.size_gb ?? null) : null;

  const showChart = byBytes && diskAvailable.length > 0;
  const key = diskSelected;
  // Panning replaces only these two arrays -- the Used rows above and
  // every other Storage field keep reading the live `m`/`d` props, per the
  // parent plan's "Panel wiring" rule.
  const seriesM = diskSeries.data && !('error' in diskSeries.data) ? diskSeries.data : undefined;
  // used and total must come from the same payload -- pairing a panned used
  // array with the live totals divides across two different windows.
  const src = seriesM ?? (m && !('error' in m) ? m : undefined);
  const dataBytesAtRange = key ? src?.disk_used_bytes_data?.ranges[key] : undefined;
  const rootBytesAtRange = key ? src?.disk_used_bytes_root?.ranges[key] : undefined;
  const dataAtRange = key
    ? pctRange(src?.disk_used_bytes_data, src?.disk_total_bytes_data, key)
    : undefined;
  const rootAtRange = key
    ? pctRange(src?.disk_used_bytes_root, src?.disk_total_bytes_root, key)
    : undefined;
  const rangeCount = Math.max(dataAtRange?.length ?? 0, rootAtRange?.length ?? 0);
  const chartSeries: ChartSeries[] = [];
  if (showChart && m && !('error' in m) && key) {
    if (m.disk_used_bytes_data && dataAtRange) {
      chartSeries.push({ values: dataAtRange, colorVar: '--gw-chart-1' });
    }
    if (m.disk_used_bytes_root && rootAtRange) {
      chartSeries.push({ values: rootAtRange, colorVar: '--gw-chart-2' });
    }
  }

  function keyItems(): ComponentChildren[] {
    if (!showChart || !m || 'error' in m || !key) return [];
    if (diskIndex === null) {
      const items: ComponentChildren[] = [];
      if (m.disk_used_bytes_data) {
        const pct = pctCurrent(m.disk_used_bytes_data, m.disk_total_bytes_data);
        items.push(
          <LegendPair
            key="data"
            cls="c-chart1"
            label={`data ${fmtPct(pct, 1)} (${fmtBytes(m.disk_used_bytes_data.current)})`}
          />,
        );
      }
      if (m.disk_used_bytes_root) {
        const pct = pctCurrent(m.disk_used_bytes_root, m.disk_total_bytes_root);
        items.push(
          <LegendPair
            key="root"
            cls="c-chart2"
            label={`root ${fmtPct(pct, 1)} (${fmtBytes(m.disk_used_bytes_root.current)})`}
          />,
        );
      }
      return items;
    }
    const dataPctV = dataAtRange?.[diskIndex];
    const rootPctV = rootAtRange?.[diskIndex];
    const dataBytesV = dataBytesAtRange?.[diskIndex];
    const rootBytesV = rootBytesAtRange?.[diskIndex];
    const items: ComponentChildren[] = [];
    if (m.disk_used_bytes_data)
      items.push(
        <LegendPair
          key="data"
          cls="c-chart1"
          label={`data ${fmtPct(dataPctV, 1)} (${fmtBytes(dataBytesV)})`}
        />,
      );
    if (m.disk_used_bytes_root)
      items.push(
        <LegendPair
          key="root"
          cls="c-chart2"
          label={`root ${fmtPct(rootPctV, 1)} (${fmtBytes(rootBytesV)})`}
        />,
      );
    items.push(
      <span key="when">
        {relativeLabel(key, diskIndex, rangeCount, diskEnd !== null ? diskSeries.end : null)}
      </span>,
    );
    return items;
  }

  function describeIndex(i2: number): string {
    if (!key) return '';
    const dataPctV = dataAtRange?.[i2];
    const rootPctV = rootAtRange?.[i2];
    const dataBytesV = dataBytesAtRange?.[i2];
    const rootBytesV = rootBytesAtRange?.[i2];
    return `data ${fmtPct(dataPctV, 1)} (${fmtBytes(dataBytesV)}), root ${fmtPct(rootPctV, 1)} (${fmtBytes(rootBytesV)}), ${relativeLabel(key, i2, rangeCount, diskEnd !== null ? diskSeries.end : null)}`;
  }

  return (
    <Card title="Storage">
      <div class="subgrid">
        <VolumeColumn
          title="Data volume"
          v={dataVolume}
          used={byBytes ? usedRow(m, 'data') : null}
        />
        <VolumeColumn
          title="Root volume"
          v={rootVolume}
          used={byBytes ? usedRow(m, 'root') : null}
        />
        <div>
          <h4>Media</h4>
          <Kv
            pairs={[
              ['Media size', fmtBytes(d.bucket_size_bytes)],
              ['Media objects', hasObjectCount ? d.bucket_object_count : null],
            ]}
          />
          {hasObjectCount && (
            <p class="note">
              Count includes non-current versions, which expire 90 days after replacement.
            </p>
          )}
        </div>
      </div>
      {byBytes && (dataVolume || rootVolume) && (
        <p class="note">
          Size is the volume's raw allocation; Used is against the filesystem's usable capacity,
          which is smaller (ext4 metadata overhead) -- the two numbers describe different things and
          won't match exactly.
        </p>
      )}
      {d.volume_error && <ErrNote message={d.volume_error} />}
      {showChart && (
        <div>
          <h4>Disk used</h4>
          <RangeSelector
            available={diskAvailable}
            selected={diskSelected ?? ''}
            onSelect={(v) => setDiskSelected(v as RangeKey)}
          />
          {canPan && key && (
            <WindowNav range={key} end={diskEnd} echoedEnd={diskSeries.end} onChange={setDiskEnd} />
          )}
          {diskSeries.error && <ErrNote message={diskSeries.error} />}
          <div
            class={diskSeries.loading ? 'panning' : undefined}
            aria-busy={diskSeries.loading || undefined}
          >
            {chartSeries.length > 0 && (
              <>
                <LineChart
                  series={chartSeries}
                  opts={{
                    min: 0,
                    max: 100,
                    yFormat: (v) => v + '%',
                    ...windowAxisLabels(key, diskEnd !== null ? diskSeries.end : null),
                    compact: true,
                    ariaLabel: `Disk percent used, last ${key}`,
                    describeIndex,
                  }}
                  inspect={{ index: diskIndex, onIndex: setDiskIndex }}
                />
                <Inspector>{keyItems()}</Inspector>
              </>
            )}
          </div>
          {m && !('error' in m) && (
            <>
              {m.disk_used_bytes_data_error && <ErrNote message={m.disk_used_bytes_data_error} />}
              {m.disk_total_bytes_data_error && <ErrNote message={m.disk_total_bytes_data_error} />}
              {m.disk_used_bytes_root_error && <ErrNote message={m.disk_used_bytes_root_error} />}
              {m.disk_total_bytes_root_error && <ErrNote message={m.disk_total_bytes_root_error} />}
            </>
          )}
        </div>
      )}
      {meter && (
        <>
          <p class="note">
            {`Disk used: ${meter.usedPct.toFixed(1)}% of ${meter.sizeGb} GiB (${meter.usedGb.toFixed(1)} GiB)`}
          </p>
          <Bar
            fraction={meter.usedPct / 100}
            ariaLabel={`Disk used, ${meter.usedPct.toFixed(1)} percent of ${meter.sizeGb} gibibytes`}
          />
          {meter.error && <ErrNote message={meter.error} />}
        </>
      )}
    </Card>
  );
}
