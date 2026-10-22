/**
 * Derives every payload shape the test suite needs from the one checked-in
 * fixture (tests/fixtures/status-data-full.json), mirroring the three
 * server-side transforms that turn that same full panel set into what a
 * real caller actually receives:
 *  - payloadFor(): collect_status()'s branch list --
 *    a disabled panel's key is absent, not null or {}.
 *  - publicPayload(): public_response()'s redaction allowlist
 *    in status.py -- reliability verbatim, incidents trimmed to
 *    started/duration_s/cause/planned.
 *  - degradedPayload(): safe_section()'s own failure shape
 *    ({"error": ...}), for the panels a test wants to force into that
 *    state.
 *
 * Deliberately NOT new fixture files: a pre-commit hook validates every
 * *.json under tests/fixtures/ against status_payload.schema.json, and
 * neither the public-route shape nor a degraded panel is a valid
 * GETStatusDataResponse on its own -- keeping the fixture glob narrow to
 * "the one full payload" is the stronger invariant, so every other shape
 * is derived in TS instead.
 */
import type {
  Change,
  Episode,
  GETStatusDataResponse,
  HostMetricSeries,
} from '../../src/generated/status-payload.d.ts';
import type { GETStatusSeriesResponse } from '../../src/generated/status-series.d.ts';
import type { RangeKey } from '../../src/status/ranges.ts';
// The import attribute is required by Playwright's own ESM loader (esbuild,
// not Vite) even though Vitest/Vite resolve a plain JSON import without one.
import fullFixtureJson from '../fixtures/status-data-full.json' with { type: 'json' };
import type { Toggles } from './shell.ts';

const fullFixture = fullFixtureJson as unknown as GETStatusDataResponse;

/** Same four keys shell.ts's disabledPanels() gates -- see that file. */
const PANEL_TOGGLE_KEYS = ['backups', 'assistant', 'cost', 'host_metrics'] as const;

/**
 * The full /_status/data response for a given toggle set: every panel
 * present in the fixture, minus whichever of backups/assistant/cost/
 * host_metrics this toggle set has off.
 */
export function payloadFor(toggles: Toggles): GETStatusDataResponse {
  const data = structuredClone(fullFixture);
  for (const key of PANEL_TOGGLE_KEYS) {
    if (!toggles[key]) delete data[key];
  }
  return data;
}

/**
 * The full payload with host_metrics' disk series swapped from the
 * checked-in fixture's byte path (VOLUME_METRICS_ENABLED on) to the default
 * configuration's single disk_used_percent (VOLUME_METRICS_ENABLED off) --
 * status.py's own mutually exclusive HOST_METRIC_SPECS arms, derived here
 * rather than shipped as a second fixture file for the same reason
 * publicPayload()/degradedPayload() are derived (see the module docstring).
 * The percent series is computed from the byte fixture's own numbers
 * (used/total per bucket), not a second synthetic value, so the two paths
 * describe the same underlying disk history.
 */
export function percentDiskPayload(): GETStatusDataResponse {
  const data = structuredClone(fullFixture);
  const hm = data.host_metrics;
  if (!hm || 'error' in hm) return data;

  const used = hm.disk_used_bytes_data;
  const totalCurrent = hm.disk_total_bytes_data?.current ?? null;
  const ranges: HostMetricSeries['ranges'] = {};
  if (used && totalCurrent) {
    for (const [key, values] of Object.entries(used.ranges) as [
      keyof HostMetricSeries['ranges'],
      (number | null)[],
    ][]) {
      ranges[key] = values.map((v) =>
        v === null ? null : Math.round((v / totalCurrent) * 1000) / 10,
      );
    }
  }

  data.host_metrics = {
    cpu_percent: hm.cpu_percent,
    cpu_percent_error: hm.cpu_percent_error,
    mem_used_percent: hm.mem_used_percent,
    mem_used_percent_error: hm.mem_used_percent_error,
    disk_used_percent: {
      current:
        used?.current !== null && used?.current !== undefined && totalCurrent
          ? Math.round((used.current / totalCurrent) * 1000) / 10
          : null,
      ranges,
    },
  };
  return data;
}

/**
 * The full payload with disk_total_bytes_data stepped mid-30d-range -- the
 * live shape of an ASG replacing the app instance with a differently-sized
 * data volume (see the Storage panel plan's "Why per-cell division"). The
 * first half of the range carries double the fixture's own total; the
 * second half (including `current`) is untouched. A percent computed by
 * dividing every cell by *today's* total would restate the whole window at
 * one size; per-cell division must show a step at the resize instead.
 */
export function diskResizePayload(): GETStatusDataResponse {
  const data = structuredClone(fullFixture);
  const hm = data.host_metrics;
  if (!hm || 'error' in hm) return data;
  const total = hm.disk_total_bytes_data;
  const range = total?.ranges['30d'];
  if (!total || !range) return data;
  const resizeAt = Math.floor(range.length / 2);
  total.ranges['30d'] = range.map((v, i) => (i < resizeAt || v === null ? v : v * 2));
  return data;
}

/**
 * The full payload with one 30d cell of disk_total_bytes_root zeroed out --
 * a filesystem total that failed to publish for that bucket. Used to prove
 * the percent-of-capacity chart renders a gap (null), not Infinity or NaN,
 * when a cell's denominator is missing.
 */
export function diskZeroTotalPayload(): GETStatusDataResponse {
  const data = structuredClone(fullFixture);
  const hm = data.host_metrics;
  if (!hm || 'error' in hm) return data;
  const total = hm.disk_total_bytes_root;
  const range = total?.ranges['30d'];
  if (!total || !range || range.length === 0) return data;
  const zeroAt = range.length - 1;
  total.ranges['30d'] = range.map((v, i) => (i === zeroAt ? 0 : v));
  return data;
}

/**
 * The full payload with both Rollout deployments' commit nulled -- the live
 * state when the newest CodeDeploy executions were Auto Scaling-triggered
 * and deployment_commits() finds no pipeline execution or same-revision
 * deployment to inherit a SHA from (see status.py's DeploymentCommitsTests).
 * The AMI's own git_sha is untouched, so this is what proves the Machine
 * image Commit link no longer depends on the Rollout block resolving one.
 */
export function noRolloutCommitPayload(): GETStatusDataResponse {
  const data = structuredClone(fullFixture);
  const dep = data.deployment;
  if (!dep || 'error' in dep) return data;
  if (dep.latest) dep.latest.commit = null;
  if (dep.latest_succeeded) dep.latest_succeeded.commit = null;
  return data;
}

type PublicIncident = Pick<Episode, 'started' | 'duration_s' | 'cause' | 'planned'>;

type PublicChange = Pick<Change, 'at' | 'kind' | 'creator' | 'outcome'>;

export interface PublicPayload {
  reliability: GETStatusDataResponse['reliability'];
  incidents: PublicIncident[] | { error: string };
  changes: PublicChange[] | { error: string };
  interruptions: { time: string }[] | { error: string };
  spot_enabled: boolean;
}

/** status.py's DELIBERATE_DEPLOYMENT_CREATORS, as the test env sets it. */
const DELIBERATE_CREATORS = ['user', 'codeDeployRollback'];

/**
 * GET /_status/public's body when PUBLIC_RELIABILITY is on: reliability
 * republished whole, incidents, changes, and Spot warnings
 * trimmed to public_response()'s allowlist (public_sections() in status.py)
 * -- instance details, ids, and descriptions are dropped at the source, not
 * hidden client-side; only deliberate changes are listed.
 */
export function publicPayload(): PublicPayload {
  return publicFrom(structuredClone(fullFixture));
}

/** The redaction half of publicPayload(), for a payload a test has already reshaped. */
export function publicFrom(data: GETStatusDataResponse): PublicPayload {
  const { incidents, changes, interruptions } = data;
  return {
    spot_enabled: data.spot_enabled,
    reliability: data.reliability,
    incidents: Array.isArray(incidents)
      ? incidents.map((ep) => ({
          started: ep.started,
          duration_s: ep.duration_s,
          cause: ep.cause,
          planned: ep.planned,
        }))
      : incidents,
    changes: Array.isArray(changes)
      ? changes
          .filter((c) => c.kind !== 'deploy' || DELIBERATE_CREATORS.includes(c.creator ?? ''))
          .map((c) => ({ at: c.at, kind: c.kind, creator: c.creator, outcome: c.outcome }))
      : changes,
    interruptions: Array.isArray(interruptions)
      ? interruptions.map((w) => ({ time: w.time }))
      : interruptions,
  };
}

/**
 * The full payload for a deployment with no Spot history: no spot-reclaim
 * episodes and no warnings, with spot_enabled as given -- the shapes the
 * Spot panel's "On-Demand, absent" and "Spot, present at zero" arms need.
 */
export function quietSpotPayload(spotEnabled: boolean): GETStatusDataResponse {
  const data = structuredClone(fullFixture);
  data.spot_enabled = spotEnabled;
  if (Array.isArray(data.incidents)) {
    data.incidents = data.incidents.filter((ep) => ep.cause !== 'spot-reclaim');
  }
  data.interruptions = [];
  return data;
}

/**
 * The full payload with the named panels replaced by safe_section()'s own
 * failure shape ({"error": message}) -- what a timed-out or AWS-erroring
 * branch looks like on the wire, for status-render.test.ts's degraded
 * snapshot and status-e2e's status-degraded.spec.ts.
 */
export function degradedPayload(
  panels: readonly (keyof GETStatusDataResponse)[],
  message = 'ThrottlingException: Rate exceeded',
): GETStatusDataResponse {
  const data = structuredClone(fullFixture);
  // GETStatusDataResponse has no index signature (every field is named), so
  // assigning through a computed `panel` key needs a real escape hatch --
  // `as unknown as Record<...>` rather than a direct cast, which TS
  // rightly refuses as too different a shape to be a plausible mistake.
  const writable = data as unknown as Record<string, unknown>;
  for (const panel of panels) {
    writable[panel] = { error: message };
  }
  return data;
}

/**
 * A GET /api/metadata/ body -- straight from the Gramps Web API, not this
 * Lambda (see status.html's fetchMetadata() comment). Only the two fields
 * renderDeployment() reads.
 */
export function metadata(): { gramps_version: string; server_version: string } {
  return { gramps_version: '6.1.6', server_version: '26.7.1' };
}

/**
 * GET /_status/series's body for one panel/range/end: the same checked-in
 * fixture, narrowed to that one range key -- same "derive rather than
 * duplicate" approach as payloadFor()/publicPayload() above.
 * `panel`/`range`/`end` are echoed verbatim (series_response()'s own
 * contract), independent of whether the server actually recognizes them --
 * an unknown panel yields `data: {error: ...}`, matching a real 404's
 * *shape* even though the real route would have already 404d by then;
 * tests/support/server.ts's caller is expected to reject an unknown panel
 * before ever calling this.
 *
 * Reliability's cells are deliberately forced into the bad band (not a
 * verbatim copy of the live payload's own mostly-good cells) -- this is
 * what makes a panned strip visibly different from the live one to a
 * Playwright assertion, the same way a real panned window (a different
 * moment in time) would look different by coincidence rather than by
 * construction.
 */
export function seriesFor(
  toggles: Toggles,
  panel: string,
  range: RangeKey,
  end: string,
): GETStatusSeriesResponse {
  const data = payloadFor(toggles);

  if (panel === 'reliability' && !('error' in data.reliability)) {
    const live = data.reliability.ranges[range];
    if (live) {
      return {
        panel,
        range,
        end,
        data: {
          ranges: {
            [range]: {
              ...live,
              // avg alone isn't enough to force every cell into the bad
              // band: cellClass() checks `!cell.samples` first (status.py's
              // own no-data case), and the live fixture always has at least
              // one such cell (see make-fixture.ts's ~4% gap rate) -- so
              // samples/expected_samples/partial are overridden too, or
              // that one cell would stay gray regardless of avg.
              cells: live.cells.map((c) => ({
                ...c,
                avg: 0.3,
                samples: 60,
                expected_samples: 60,
                partial: false,
              })),
            },
          },
          slo_good_threshold: data.reliability.slo_good_threshold,
          slo_warn_threshold: data.reliability.slo_warn_threshold,
          decimals: data.reliability.decimals,
        },
      };
    }
  }

  if (panel === 'host_metrics' && data.host_metrics && !('error' in data.host_metrics)) {
    const hm = data.host_metrics;
    const narrow = (s: HostMetricSeries | undefined): HostMetricSeries | undefined =>
      s && { current: s.current, ranges: { [range]: s.ranges[range] } };
    return {
      panel,
      range,
      end,
      data: {
        cpu_percent: narrow(hm.cpu_percent),
        mem_used_percent: narrow(hm.mem_used_percent),
        disk_used_bytes_data: narrow(hm.disk_used_bytes_data),
        disk_total_bytes_data: narrow(hm.disk_total_bytes_data),
        disk_used_bytes_root: narrow(hm.disk_used_bytes_root),
        disk_total_bytes_root: narrow(hm.disk_total_bytes_root),
      },
    };
  }

  if (panel === 'assistant' && data.assistant && !('error' in data.assistant)) {
    const a = data.assistant;
    return {
      panel,
      range,
      end,
      data: { ...a, token_ranges: { [range]: a.token_ranges[range] } },
    };
  }

  return {
    panel: panel as GETStatusSeriesResponse['panel'],
    range,
    end,
    data: { error: `unknown panel: ${panel}` },
  };
}
