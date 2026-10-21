/**
 * Regenerates tests/fixtures/status-data-full.json at full RANGES/
 * CHART_RANGES fidelity: `npm run fixtures:regen`.
 *
 * The checked-in fixture this replaces had one range and two cells -- too
 * thin to be an oracle for the toggle matrix or the render snapshots. This script rebuilds it against
 * status.py's real shape (RANGES around :162, CHART_RANGES around :180):
 * all five reliability ranges at their real cell counts (24h=24, 7d=28,
 * 30d=30, 90d=90, 1y=52), the latency series at the same counts, and
 * host_metrics/assistant chart series at CHART_RANGES lengths
 * (24h=48, 7d=168, 30d=30, 90d=90, 1y=365).
 *
 * Deterministic: a seeded PRNG (mulberry32) plus one fixed reference
 * instant, so re-running this script with no code change produces a
 * byte-identical file -- a no-op `git diff`, the way any other codegen
 * step in this repo behaves.
 *
 * Synthetic values only: every identifier below (instance/volume/AMI ids,
 * account id, IPs-shaped strings) is generated from the seeded PRNG, never
 * copied from a real deployment -- this is a public repo, and
 * status_payload.schema.json's own description is what a pre-commit hook
 * validates this file against on every commit.
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import type {
  Assistant,
  Change,
  Episode,
  GETStatusDataResponse,
  HostMetricSeries,
  Interruption,
  ReliabilityCell,
  TokenSeries,
} from '../../src/generated/status-payload.d.ts';
import type { GETStatusSeriesResponse } from '../../src/generated/status-series.d.ts';

const OUT_PATH = fileURLToPath(new URL('../fixtures/status-data-full.json', import.meta.url));
const SERIES_DIR = new URL('../fixtures/series/', import.meta.url);

// Arbitrary, fixed -- every timestamp and "ago" computation below is
// anchored to this instant rather than Date.now(), which is what makes
// regeneration a no-op diff. Matches tests/support/mount.ts's frozen clock
// so a snapshot's Cost projection (the one panel that reads the wall clock,
// for its month-to-date budget projection) is generated under the same
// "now" it will later render under, though nothing here requires that to
// be true.
const NOW_MS = Date.parse('2026-06-15T12:00:00Z');

// Mulberry32: small, fast, seeded, good enough uniformity for synthetic
// test data (not for anything security- or simulation-sensitive).
function mulberry32(seed: number): () => number {
  let a = seed;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const rnd = mulberry32(0x67a55e5);

function hex(len: number): string {
  let s = '';
  for (let i = 0; i < len; i++) s += Math.floor(rnd() * 16).toString(16);
  return s;
}

function pick<T>(items: readonly T[]): T {
  const item = items[Math.floor(rnd() * items.length)];
  if (item === undefined) throw new Error('pick: empty list');
  return item;
}

function isoAt(offsetMs: number): string {
  return new Date(NOW_MS + offsetMs).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

// --- reliability --------------------------------------------------------

type RangeKey = '24h' | '7d' | '30d' | '90d' | '1y';
const RANGE_ORDER: RangeKey[] = ['24h', '7d', '30d', '90d', '1y'];

// Mirrors status.py's RANGES dict (cells, cell_s only -- period_s/query_days
// are query-shaping concerns with no payload footprint).
const RANGES_META: Record<RangeKey, { cells: number; cellS: number }> = {
  '24h': { cells: 24, cellS: 3600 },
  '7d': { cells: 28, cellS: 21600 },
  '30d': { cells: 30, cellS: 86400 },
  '90d': { cells: 90, cellS: 86400 },
  '1y': { cells: 52, cellS: 604800 },
};

// Mirrors status.py's CHART_RANGES dict (host_metrics / assistant token
// series length per range).
const CHART_RANGES_META: Record<RangeKey, number> = {
  '24h': 48,
  '7d': 168,
  '30d': 30,
  '90d': 90,
  '1y': 365,
};

// Reproduces status.py's cell_label() three-way format so a snapshot's cell
// titles/labels look like production output.
function cellLabel(startMs: number, widthS: number): string {
  const start = new Date(startMs);
  if (widthS >= 604800) {
    const end = new Date(startMs + widthS * 1000 - 86400000);
    return `${start.toISOString().slice(0, 10)} – ${end.toISOString().slice(0, 10)}`;
  }
  if (widthS >= 86400) return start.toISOString().slice(0, 10);
  const iso = start.toISOString();
  return `${iso.slice(0, 10)} ${iso.slice(11, 16)}`;
}

function floorToMs(ms: number, stepS: number): number {
  const stepMs = stepS * 1000;
  return Math.floor(ms / stepMs) * stepMs;
}

function buildCells(range: RangeKey): ReliabilityCell[] {
  const { cells, cellS } = RANGES_META[range];
  const alignS = Math.min(cellS, 86400);
  const stripEnd = floorToMs(NOW_MS, alignS) + alignS * 1000;
  const stripStart = stripEnd - cells * cellS * 1000;

  return Array.from({ length: cells }, (_, i) => {
    const startMs = stripStart + i * cellS * 1000;
    const isLast = i === cells - 1;
    // ~4% of non-trailing cells carry no data (a canary gap), a further
    // slice dips into the warn/bad bands, and the rest sit in the good
    // band -- enough spread that every legend swatch on the page (good,
    // warn, bad, no-data, in-progress) has at least one real cell behind
    // it across the five ranges.
    const noData = !isLast && rnd() < 0.04;
    let avg: number | null = null;
    if (!noData) {
      const roll = rnd();
      avg =
        roll < 0.05
          ? 0.85 + rnd() * 0.08
          : roll < 0.15
            ? 0.96 + rnd() * 0.03
            : 0.999 + rnd() * 0.001;
      avg = Math.min(1, avg);
    }
    const samples = noData ? 0 : Math.round(50 + rnd() * 15);
    return {
      label: cellLabel(startMs, cellS),
      avg,
      samples,
      partial: isLast,
      expected_samples: noData ? null : 60,
    };
  });
}

function weightedUptime(cells: ReliabilityCell[]): number | null {
  let weighted = 0;
  let total = 0;
  for (const cell of cells) {
    if (cell.avg === null || !cell.samples) continue;
    weighted += cell.avg * cell.samples;
    total += cell.samples;
  }
  return total ? Math.round(((100 * weighted) / total) * 1000) / 1000 : null;
}

function buildLatency(count: number): { p50: number | null; p90: number | null }[] {
  return Array.from({ length: count }, (_, i) => {
    // A rare gap: a probe that failed before an HTTP status came back.
    if (rnd() < 0.03) return { p50: null, p90: null };
    const p50 = Math.round(45 + rnd() * 40 + Math.sin(i / 5) * 10);
    const p90 = Math.round(p50 * (1.2 + rnd() * 0.3));
    return { p50, p90 };
  });
}

function buildReliability(): GETStatusDataResponse['reliability'] {
  const ranges: NonNullable<
    Extract<GETStatusDataResponse['reliability'], { ranges: unknown }>
  >['ranges'] = {};
  for (const key of RANGE_ORDER) {
    const cells = buildCells(key);
    const uptime = weightedUptime(cells);
    ranges[key] = {
      uptime,
      // Excluding planned windows never lowers uptime -- nudge up slightly
      // and clamp, same direction status.py's real subtraction-from-
      // downtime arithmetic always moves in.
      uptime_excl_planned:
        uptime === null ? null : Math.min(100, Math.round((uptime + 0.02) * 1000) / 1000),
      cells,
      latency: {
        probe: buildLatency(RANGES_META[key].cells),
      },
      cell_s: RANGES_META[key].cellS,
      checks: Math.round((86400 / RANGES_META[key].cellS) * RANGES_META[key].cells * 60),
    };
  }
  return {
    ranges,
    slo_good_threshold: 0.999,
    slo_warn_threshold: 0.95,
    decimals: 3,
  };
}

// --- incidents ------------------------------------------------------------

// availability.py's classify_cause() vocabulary in full (see
// status_payload.schema.json's Episode.cause enum) -- one episode per
// cause so every cause label the page can render appears at least once.
// planned/unplanned assignment here is a synthetic, illustrative split for
// coverage, not a reproduction of availability.py's actual PLANNED_CAUSES
// list (out of scope for a frontend fixture).
const CAUSES: { cause: Episode['cause']; planned: boolean }[] = [
  { cause: 'deploy', planned: true },
  { cause: 'rightsize', planned: true },
  { cause: 'instance-refresh', planned: true },
  { cause: 'capacity-change', planned: true },
  { cause: 'spot-reclaim', planned: false },
  { cause: 'health-watchdog', planned: false },
  { cause: 'health-replace', planned: false },
  { cause: 'backup', planned: true },
  { cause: 'unknown', planned: false },
];

const INSTANCE_TYPES = ['t3a.medium', 't3a.small', 't3.medium'] as const;
const AZS = ['us-east-1a', 'us-east-1b', 'us-east-1c'] as const;

function buildInstanceRef(offsetMs: number, withTime: boolean): Episode['new_instance'] {
  const launched = isoAt(offsetMs);
  return {
    id: `i-0${hex(17)}`,
    type: pick(INSTANCE_TYPES),
    az: pick(AZS),
    arch: 'x86_64',
    launched,
    ...(withTime ? { time: launched } : {}),
  };
}

function buildCauseIncidents(): Episode[] {
  return CAUSES.map(({ cause, planned }, i) => {
    // Oldest first offset, newest last -- reversed below to match
    // incidents()'s own newest-first sort.
    const startOffsetMs = -(CAUSES.length - i) * 21 * 24 * 60 * 60 * 1000;
    const durationS = Math.round(90 + rnd() * 2500);
    const isSpotReclaim = cause === 'spot-reclaim';
    return {
      started: isoAt(startOffsetMs),
      ended: isoAt(startOffsetMs + durationS * 1000),
      duration_s: durationS,
      cause,
      planned,
      // Only the spot-reclaim episode carries an old_instance -- the one
      // shape the frontend renders differently (an old->new instance
      // swap).
      old_instance: isSpotReclaim ? buildInstanceRef(startOffsetMs - 60_000, true) : null,
      new_instance: buildInstanceRef(startOffsetMs + durationS * 1000, false),
      capacity_wait_s: Math.floor(durationS / 2),
      boot_to_serve_s: durationS - Math.floor(durationS / 2),
      lifecycle: 'spot' as const,
      spot_price: 0.0163,
    };
  }).reverse();
}

// Deterministic literals, no rnd(): the Spot history below must not shift the
// values every later builder draws from the seeded generator. Eight pools so
// the pool table has an "Other" row; the last two are single reclaims. The
// recent reclaims carry recovery timing, the older ones predate it, and the
// oldest also predate the old_instance record.
const SPOT_POOLS = [
  ['m8g.medium', 'us-east-1b'],
  ['m8g.medium', 'us-east-1c'],
  ['m7g.medium', 'us-east-1a'],
  ['t4g.medium', 'us-east-1b'],
  ['m7g.medium', 'us-east-1b'],
  ['m6g.medium', 'us-east-1c'],
  ['m6gd.medium-with-a-deliberately-long-name', 'us-east-1a'],
  ['c7g.large', 'us-east-1d'],
] as const;

// Days before NOW_MS, newest first.
const SPOT_RECLAIM_DAYS_AGO = [
  1.6, 4.3, 9.1, 11.8, 16.2, 22.5, 27.0, 33.4, 40.1, 41.0, 55.2, 61.7, 68.9, 76.3, 83.5, 97.0,
  118.2, 140.5, 163.9, 205.6, 251.3, 300.8, 330.4,
];
const SPOT_POOL_INDEX = [0, 0, 1, 0, 2, 3, 0, 1, 4, 0, 5, 1, 0, 2, 6, 0, 3, 1, 7, 0, 2, 4, 0];
const SPOT_TIMED_COUNT = 9;
const SPOT_RECORDED_INSTANCE_COUNT = 21;

function buildSpotEpisodes(): Episode[] {
  const day = 24 * 60 * 60 * 1000;
  return SPOT_RECLAIM_DAYS_AGO.map((daysAgo, i) => {
    const startOffsetMs = -Math.round(daysAgo * day);
    const durationS = 150 + ((i * 97) % 420);
    const pool = SPOT_POOLS[SPOT_POOL_INDEX[i] ?? 0] ?? SPOT_POOLS[0];
    const lifetimeS = (6 + ((i * 37) % 150)) * 3600;
    const timed = i < SPOT_TIMED_COUNT;
    const capacityWaitS = Math.round(durationS * (0.35 + 0.05 * (i % 4)));
    const id = String(i).padStart(2, '0');
    return {
      started: isoAt(startOffsetMs),
      ended: isoAt(startOffsetMs + durationS * 1000),
      duration_s: durationS,
      cause: 'spot-reclaim' as const,
      planned: false,
      ...(timed
        ? {
            capacity_wait_s: capacityWaitS,
            boot_to_serve_s: durationS - capacityWaitS,
            lifecycle: 'spot' as const,
            spot_price: 0.0163,
          }
        : {}),
      old_instance:
        i < SPOT_RECORDED_INSTANCE_COUNT
          ? {
              id: `i-0spot0000000000${id}`,
              type: pool[0],
              az: pool[1],
              arch: 'arm64',
              launched: isoAt(startOffsetMs - lifetimeS * 1000),
              time: isoAt(startOffsetMs - 90_000),
            }
          : null,
      new_instance: {
        id: `i-0spot1000000000${id}`,
        type: pool[0],
        az: pool[1],
        arch: 'arm64',
        launched: isoAt(startOffsetMs + durationS * 1000),
      },
    };
  });
}

function buildIncidents(): Episode[] {
  return [...buildCauseIncidents(), ...buildSpotEpisodes()].sort((a, b) =>
    a.started < b.started ? 1 : -1,
  );
}

// Deterministic literals, no rnd(): adding them must not shift the values
// every later builder draws from the seeded generator.
function buildChanges(): Change[] {
  const day = 24 * 60 * 60 * 1000;
  const changes: Change[] = [
    {
      at: isoAt(-2 * day),
      kind: 'deploy',
      id: 'd-ABCDEFGH1',
      creator: 'user',
      outcome: 'succeeded',
      duration_s: 240,
      description: null,
      outage: false,
    },
    {
      at: isoAt(-4 * day),
      kind: 'deploy',
      id: 'd-ABCDEFGH4',
      creator: 'codeDeployRollback',
      outcome: 'rollback-succeeded',
      duration_s: 310,
      description: 'Rolled back to the previous revision',
      outage: true,
    },
    {
      at: isoAt(-9 * day),
      kind: 'instance-refresh',
      id: '00000000-0000-4000-8000-000000000001',
      creator: null,
      outcome: 'succeeded',
      duration_s: 420,
      description: null,
      outage: true,
    },
    {
      at: isoAt(-12 * day),
      kind: 'deploy',
      id: 'd-ABCDEFGH3',
      creator: 'user',
      outcome: 'stopped',
      duration_s: 95,
      description: null,
      outage: false,
    },
    {
      at: isoAt(-17 * day),
      kind: 'deploy',
      id: 'd-ABCDEFGH5',
      creator: 'autoscaling',
      outcome: 'succeeded',
      duration_s: 45,
      description: null,
      outage: false,
    },
    {
      at: isoAt(-30 * day),
      kind: 'deploy',
      id: 'd-ABCDEFGH2',
      creator: 'autoscaling',
      outcome: 'failed',
      duration_s: null,
      description: null,
      outage: false,
    },
    {
      at: isoAt(-44 * day),
      kind: 'deploy',
      id: 'd-ABCDEFGH6',
      creator: 'user',
      outcome: 'succeeded',
      duration_s: 260,
      description: null,
      outage: false,
    },
  ];
  return changes;
}

// One warning ahead of every Spot outage, plus extra ones the instance
// survived or recovered from within the outage threshold (some weeks hold
// several, some none), so "absorbed" is non-zero in most weeks.
const ABSORBED_WARNING_DAYS_AGO = [
  3, 17, 6.2, 6.5, 13.4, 19.9, 19.95, 24.1, 29.0, 35.6, 36.2, 36.4, 47.3, 58.8, 70.2, 70.4, 88.1,
  102.7, 131.0, 131.2, 131.6, 175.5, 222.8, 268.0,
];

function buildInterruptions(): Interruption[] {
  const day = 24 * 60 * 60 * 1000;
  const beforeOutage = SPOT_RECLAIM_DAYS_AGO.map((d) => -Math.round(d * day) - 120_000);
  const absorbed = ABSORBED_WARNING_DAYS_AGO.map((d) => -Math.round(d * day));
  return [...beforeOutage, ...absorbed]
    .sort((a, b) => b - a)
    .map((offsetMs, i) => ({
      time: isoAt(offsetMs),
      instance_id: `i-0${String(i).padStart(17, '0')}`,
      action: 'terminate',
    }));
}

// --- host / image -----------------------------------------------------------

function buildHostAndImage(): {
  host: GETStatusDataResponse['host'];
  image: GETStatusDataResponse['image'];
  rootVolumeId: string;
} {
  const amiId = `ami-0${hex(17)}`;
  const instanceId = `i-0${hex(17)}`;
  const rootVolumeId = `vol-0${hex(17)}`;
  const launchOffsetMs = -6 * 60 * 60 * 1000;
  return {
    host: {
      capacity: { desired: 1, min: 1, max: 1 },
      instance: {
        id: instanceId,
        type: 't3a.medium',
        architecture: 'x86_64',
        az: 'us-east-1b',
        lifecycle: 'spot' as const,
        launch_time: isoAt(launchOffsetMs),
        uptime_s: Math.round(-launchOffsetMs / 1000),
        ami_id: amiId,
        root_volume_id: rootVolumeId,
      },
    },
    rootVolumeId,
    image: {
      id: amiId,
      name: `gramps-web-base-x86-${Math.floor(rnd() * 1_000_000_000)}`,
      creation_date: isoAt(-9 * 24 * 60 * 60 * 1000),
      git_sha: hex(40),
      source_ami: null,
      source_ami_name: 'al2023-ami-minimal',
      source_ami_description: 'Amazon Linux 2023 minimal image (synthetic fixture value)',
    },
  };
}

// --- storage / deployment / backups / assistant / cost / host_metrics -----

function buildStorage(rootVolumeId: string): GETStatusDataResponse['storage'] {
  return {
    volumes: [
      {
        role: 'data',
        id: `vol-0${hex(17)}`,
        device: '/dev/sdf',
        size_gb: 20,
        type: 'gp3',
        iops: 3000,
        encrypted: true,
        state: 'in-use',
      },
      {
        role: 'root',
        id: rootVolumeId,
        device: '/dev/xvda',
        size_gb: 16,
        type: 'gp3',
        iops: 3000,
        encrypted: false,
        state: 'in-use',
      },
    ],
    bucket_size_bytes: 130_150_400 + Math.floor(rnd() * 5_000_000),
    bucket_object_count: 260 + Math.floor(rnd() * 20),
  };
}

// The pipeline's own source repo (terraform/config/stack/prod/terraform.tfvars'
// repo_url), not a synthetic value -- already public elsewhere in this repo,
// and using the real owner/repo is what makes the fixture's commit links
// resolve to real GitHub URLs rather than a fake placeholder.
const SOURCE_REPO = 'example/gramps-web';

function buildDeployment(): GETStatusDataResponse['deployment'] {
  return {
    // commit is a bare SHA, resolved against the payload's top-level
    // source_repo -- deployment_commits() joins pipeline_commits() (the
    // CodeDeploy deploymentId -> pipeline Source-action SHA) with a
    // same-revision fallback for deployments Auto Scaling replayed
    // verbatim (see summarize_deployment()).
    latest: {
      id: `d-${hex(10).toUpperCase()}`,
      status: 'Succeeded',
      create_time: isoAt(-3 * 60 * 60 * 1000),
      commit: hex(40),
    },
    latest_succeeded: {
      id: `d-${hex(10).toUpperCase()}`,
      status: 'Succeeded',
      create_time: isoAt(-27 * 60 * 60 * 1000),
      commit: hex(40),
    },
    ecr_latest_image: {
      tags: ['26.7.1'],
      digest: `sha256:${hex(64)}`,
      pushed_at: isoAt(-3 * 60 * 60 * 1000),
    },
  };
}

function buildBackups(): GETStatusDataResponse['backups'] {
  return {
    mode: 'cross_account',
    schedule: 'cron(0 3 * * ? *)',
    retention_days: 7,
    resource_count: 1,
    remote_retention_days: 30,
    local: {
      name: 'gramps-web-backup',
      region: 'us-east-1',
      recovery_points: 14,
      locked: false,
    },
    latest_backup: { completed: isoAt(-9 * 60 * 60 * 1000), age_s: 9 * 60 * 60 },
    destination: {
      name: 'gramps-web-backup-replica',
      region: 'us-east-2',
      account_id: '000000000000',
      locked: true,
      recovery_points: 59,
    },
    latest_copy: { completed: isoAt(-8 * 60 * 60 * 1000), age_s: 8 * 60 * 60 },
    failed_jobs_7d: 0,
  };
}

function buildTokenSeries(count: number): TokenSeries {
  return {
    input: Array.from({ length: count }, () => Math.round(rnd() * 4000)),
    output: Array.from({ length: count }, () => Math.round(rnd() * 400)),
  };
}

function buildAssistant(): GETStatusDataResponse['assistant'] {
  // Assistant, not GETStatusDataResponse['assistant'] (which is
  // `Assistant | PanelError | undefined`): indexing into a union where one
  // member (PanelError) lacks token_ranges resolves to an unresolvable
  // type rather than an error, which is what tripped
  // @typescript-eslint/no-unsafe-member-access below before this switched
  // to the concrete type.
  const tokenRanges: Assistant['token_ranges'] = {};
  for (const key of RANGE_ORDER) tokenRanges[key] = buildTokenSeries(CHART_RANGES_META[key]);
  return {
    model_id: 'global.anthropic.claude-sonnet-4-6',
    region: 'us-east-2',
    max_requests: 30,
    max_tokens: 400_000,
    max_context_length: 100_000,
    token_ranges: tokenRanges,
  };
}

function buildCost(): GETStatusDataResponse['cost'] {
  return {
    month_to_date_usd: 21.47,
    top_services: [
      { service: 'Amazon Elastic Compute Cloud', amount_usd: 9.82 },
      { service: 'Amazon CloudFront', amount_usd: 4.11 },
      { service: 'AWS Backup', amount_usd: 2.35 },
      { service: 'Amazon Simple Storage Service', amount_usd: 1.9 },
      { service: 'Amazon CloudWatch', amount_usd: 1.42 },
      { service: 'Amazon Bedrock', amount_usd: 1.05 },
      { service: 'AWS Key Management Service', amount_usd: 0.62 },
      { service: 'Amazon Route 53', amount_usd: 0.2 },
    ],
    budget_usd: 40,
  };
}

function buildHostMetricSeries(
  current: number,
  count: (range: RangeKey) => number,
  spread: number,
): HostMetricSeries {
  const ranges: HostMetricSeries['ranges'] = {};
  for (const key of RANGE_ORDER) {
    ranges[key] = Array.from({ length: count(key) }, (_, i) =>
      Math.max(
        0,
        Math.round((current + Math.sin(i / 7) * spread + (rnd() - 0.5) * spread) * 10) / 10,
      ),
    );
  }
  return { current, ranges };
}

// The checked-in fixture carries the byte path (VOLUME_METRICS_ENABLED
// "true"): disk_used_bytes/disk_total_bytes_<data|root>, not
// disk_used_percent -- tests/support/payload.ts's percentDiskPayload()
// derives the default configuration's percent-path shape from these same
// numbers. Totals get ~zero spread (a filesystem's size doesn't fluctuate);
// used bytes get a real trend, matching the parent plan's "a trend instead
// of a level".
function buildHostMetrics(): GETStatusDataResponse['host_metrics'] {
  return {
    cpu_percent: buildHostMetricSeries(1.3, (k) => CHART_RANGES_META[k], 0.8),
    mem_used_percent: buildHostMetricSeries(51.9, (k) => CHART_RANGES_META[k], 3.5),
    disk_used_bytes_data: buildHostMetricSeries(
      214_223_698,
      (k) => CHART_RANGES_META[k],
      3_000_000,
    ),
    disk_total_bytes_data: buildHostMetricSeries(21_045_336_064, (k) => CHART_RANGES_META[k], 0),
    disk_used_bytes_root: buildHostMetricSeries(
      5_726_623_744,
      (k) => CHART_RANGES_META[k],
      60_000_000,
    ),
    disk_total_bytes_root: buildHostMetricSeries(16_857_747_456, (k) => CHART_RANGES_META[k], 0),
  };
}

// --- assembly ---------------------------------------------------------------

function build(): GETStatusDataResponse {
  const { host, image, rootVolumeId } = buildHostAndImage();
  return {
    min_role: 'member',
    caller_role: 'admin',
    gramps_web_version: '26.7.1',
    source_repo: SOURCE_REPO,
    spot_enabled: true,
    reliability: buildReliability(),
    incidents: buildIncidents(),
    changes: buildChanges(),
    interruptions: buildInterruptions(),
    host,
    image,
    storage: buildStorage(rootVolumeId),
    deployment: buildDeployment(),
    backups: buildBackups(),
    assistant: buildAssistant(),
    cost: buildCost(),
    host_metrics: buildHostMetrics(),
  };
}

const fixture = build();
writeFileSync(OUT_PATH, JSON.stringify(fixture, null, 2) + '\n');
console.log(`wrote ${OUT_PATH}`);

// --- /_status/series -------------------------------------------------------

// A panned window's own end -- 7 days before NOW_MS, so it's visibly not
// "now" (see WindowNav.tsx's "Live" vs. echoed-end distinction). Regenerated
// alongside status-data-full.json, from the same fixture, rather than a
// second hand-authored source of truth: a panned response is exactly one
// panel's ranges narrowed to a single key, which the full fixture already
// carries in full.
const SERIES_END = isoAt(-7 * 86400_000);

function writeSeriesFixture(name: string, body: GETStatusSeriesResponse): void {
  mkdirSync(SERIES_DIR, { recursive: true });
  const path = fileURLToPath(new URL(name, SERIES_DIR));
  writeFileSync(path, JSON.stringify(body, null, 2) + '\n');
  console.log(`wrote ${path}`);
}

// panel=reliability -- ranges narrowed to "24h", matching series_response()'s
// own reliability(now, keys=[range_key]) call.
if (!('error' in fixture.reliability)) {
  writeSeriesFixture('status-series-reliability.json', {
    panel: 'reliability',
    range: '24h',
    end: SERIES_END,
    data: {
      ranges: { '24h': fixture.reliability.ranges['24h'] },
      slo_good_threshold: fixture.reliability.slo_good_threshold,
      slo_warn_threshold: fixture.reliability.slo_warn_threshold,
      decimals: fixture.reliability.decimals,
    },
  });
}

// panel=host_metrics -- every metric's own `ranges` narrowed to "24h", same
// shape narrowing as above; `current` is untouched (still the live scalar --
// see host_metrics()'s docstring on why a panned request still carries it).
if (fixture.host_metrics && !('error' in fixture.host_metrics)) {
  const hm = fixture.host_metrics;
  const narrow = (s: HostMetricSeries | undefined): HostMetricSeries | undefined =>
    s && { current: s.current, ranges: { '24h': s.ranges['24h'] } };
  writeSeriesFixture('status-series-host-metrics.json', {
    panel: 'host_metrics',
    range: '24h',
    end: SERIES_END,
    data: {
      cpu_percent: narrow(hm.cpu_percent),
      mem_used_percent: narrow(hm.mem_used_percent),
      disk_used_bytes_data: narrow(hm.disk_used_bytes_data),
      disk_total_bytes_data: narrow(hm.disk_total_bytes_data),
      disk_used_bytes_root: narrow(hm.disk_used_bytes_root),
      disk_total_bytes_root: narrow(hm.disk_total_bytes_root),
    },
  });
}

// One degraded arm -- safe_section()'s own failure shape. series_response()
// can ship this for any panel on an AWS failure, and {"error": ...} is a
// real, valid GETStatusSeriesResponse in its own right -- unlike the
// data-route degraded shapes, which payload.ts's degradedPayload() derives
// from the full fixture instead of checking one in (see that function's
// docstring), so there's no equivalent derivation to reuse here.
writeSeriesFixture('status-series-degraded.json', {
  panel: 'assistant',
  range: '30d',
  end: SERIES_END,
  data: { error: 'ThrottlingException: Rate exceeded' },
});
