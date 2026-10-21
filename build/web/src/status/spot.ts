import type { Episode, Interruption, PanelError } from '../generated/status-payload';
import { RANGE_SPAN_S } from './ranges';

export type SpotRange = '30d' | '90d' | '1y';
export const SPOT_RANGES: SpotRange[] = ['30d', '90d', '1y'];
export const SPOT_DEFAULT_RANGE: SpotRange = '30d';

/** Fewest outages carrying both timing fields before the recovery split draws a bar. */
export const SPLIT_MIN_EPISODES = 3;
export const POOL_ROWS = 6;

const DAY_MS = 86400 * 1000;
const WEEK_MS = 7 * DAY_MS;
// Weeks start on Monday (ISO 8601). The epoch was a Thursday, so the Monday
// before it sits 3 days earlier; pure UTC millisecond arithmetic keeps the
// buckets independent of any local timezone or DST.
const MONDAY_OFFSET_MS = 3 * DAY_MS;

export interface WeekBucket {
  start: string;
  outages: number;
  absorbed: number;
}

export interface SpotSummary {
  reclaims: number;
  outages: number;
  absorbed: number;
  downtimeS: number;
  downtimeShare: number | null;
  medianS: number | null;
  p90S: number | null;
}

export interface RecoverySplit {
  count: number;
  capacityWaitS: number;
  bootToServeS: number;
}

export interface PoolRow {
  type: string;
  az: string;
  reclaims: number;
  medianLifetimeS: number | null;
  last: string;
}

export interface SpotData {
  episodes: Episode[];
  warnings: Interruption[];
}

function rows<T>(d: T[] | PanelError | undefined): T[] {
  return Array.isArray(d) ? d : [];
}

export function spotData(
  incidents: Episode[] | PanelError | undefined,
  interruptions: Interruption[] | PanelError | undefined,
): SpotData {
  return {
    episodes: rows(incidents),
    warnings: rows(interruptions),
  };
}

export function isSpotEpisode(ep: Episode): boolean {
  return ep.cause === 'spot-reclaim';
}

/** The panel shows for a Spot deployment, or wherever the payload's year holds any trace of a reclaim. */
export function hasSpotActivity(data: SpotData): boolean {
  return data.warnings.length > 0 || data.episodes.some(isSpotEpisode);
}

export function rangeStartMs(range: SpotRange, nowMs: number): number {
  return nowMs - RANGE_SPAN_S[range] * 1000;
}

function inRange(iso: string, range: SpotRange, nowMs: number): boolean {
  const t = Date.parse(iso);
  return t >= rangeStartMs(range, nowMs) && t <= nowMs;
}

export function warningsIn(data: SpotData, range: SpotRange, nowMs: number): Interruption[] {
  return data.warnings.filter((w) => inRange(w.time, range, nowMs));
}

export function episodesIn(data: SpotData, range: SpotRange, nowMs: number): Episode[] {
  return data.episodes.filter((ep) => inRange(ep.started, range, nowMs));
}

export function weekStartMs(ms: number): number {
  return Math.floor((ms + MONDAY_OFFSET_MS) / WEEK_MS) * WEEK_MS - MONDAY_OFFSET_MS;
}

export function median(values: number[]): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2
    ? (sorted[mid] ?? null)
    : ((sorted[mid - 1] ?? 0) + (sorted[mid] ?? 0)) / 2;
}

/** Nearest rank: the smallest value at or above fraction p of the sample. */
export function percentile(values: number[], p: number): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.max(0, Math.ceil(p * sorted.length) - 1)] ?? null;
}

/**
 * One bucket per ISO week from the week holding the range start to the week
 * holding now. Per week: outage episodes of cause spot-reclaim, and the
 * warnings beyond them (floored at zero) as absorbed. A warning cannot be
 * tied to its episode, so absorbed is approximate by construction.
 */
export function weeklyBuckets(data: SpotData, range: SpotRange, nowMs: number): WeekBucket[] {
  const first = weekStartMs(rangeStartMs(range, nowMs));
  const last = weekStartMs(nowMs);
  const count = Math.round((last - first) / WEEK_MS) + 1;
  const warnings = new Array<number>(count).fill(0);
  const outages = new Array<number>(count).fill(0);
  const bump = (counts: number[], iso: string) => {
    const i = Math.round((weekStartMs(Date.parse(iso)) - first) / WEEK_MS);
    if (i >= 0 && i < count) counts[i] = (counts[i] ?? 0) + 1;
  };
  warningsIn(data, range, nowMs).forEach((w) => bump(warnings, w.time));
  episodesIn(data, range, nowMs)
    .filter(isSpotEpisode)
    .forEach((ep) => bump(outages, ep.started));
  return outages.map((o, i) => ({
    start: new Date(first + i * WEEK_MS).toISOString(),
    outages: o,
    absorbed: Math.max(0, (warnings[i] ?? 0) - o),
  }));
}

export function summarize(data: SpotData, range: SpotRange, nowMs: number): SpotSummary {
  const spot = episodesIn(data, range, nowMs).filter(isSpotEpisode);
  const all = episodesIn(data, range, nowMs);
  const durations = spot.map((ep) => ep.duration_s);
  const downtimeS = durations.reduce((a, b) => a + b, 0);
  const totalS = all.reduce((a, ep) => a + ep.duration_s, 0);
  return {
    reclaims: warningsIn(data, range, nowMs).length,
    outages: spot.length,
    absorbed: weeklyBuckets(data, range, nowMs).reduce((a, w) => a + w.absorbed, 0),
    downtimeS,
    downtimeShare: totalS > 0 ? (downtimeS / totalS) * 100 : null,
    medianS: median(durations),
    p90S: percentile(durations, 0.9),
  };
}

/** Medians over the outages that carry both timing fields; null below SPLIT_MIN_EPISODES. */
export function recoverySplit(episodes: Episode[]): { timed: number; split: RecoverySplit | null } {
  const waits: number[] = [];
  const boots: number[] = [];
  episodes.forEach((ep) => {
    if (typeof ep.capacity_wait_s === 'number' && typeof ep.boot_to_serve_s === 'number') {
      waits.push(ep.capacity_wait_s);
      boots.push(ep.boot_to_serve_s);
    }
  });
  const capacityWaitS = median(waits);
  const bootToServeS = median(boots);
  if (waits.length < SPLIT_MIN_EPISODES || capacityWaitS === null || bootToServeS === null) {
    return { timed: waits.length, split: null };
  }
  return { timed: waits.length, split: { count: waits.length, capacityWaitS, bootToServeS } };
}

function lifetimeS(ep: Episode): number | null {
  const old = ep.old_instance;
  if (!old || !old.time) return null;
  const s = (Date.parse(old.time) - Date.parse(old.launched)) / 1000;
  return s >= 0 ? s : null;
}

interface PoolGroup {
  type: string;
  az: string;
  episodes: Episode[];
}

function poolRow(type: string, az: string, eps: Episode[]): PoolRow {
  const lifetimes = eps.map(lifetimeS).filter((s): s is number => s !== null);
  return {
    type,
    az,
    reclaims: eps.length,
    medianLifetimeS: median(lifetimes),
    last: eps.map((ep) => ep.started).reduce((a, b) => (a > b ? a : b)),
  };
}

function poolGroups(episodes: Episode[]): PoolGroup[] {
  const groups = new Map<string, PoolGroup>();
  episodes.forEach((ep) => {
    const old = ep.old_instance;
    const type = old ? old.type : 'unknown';
    const az = old ? old.az : '—';
    const key = `${type}\u0000${az}`;
    const group = groups.get(key) ?? { type, az, episodes: [] };
    group.episodes.push(ep);
    groups.set(key, group);
  });
  return [...groups.values()];
}

/**
 * Reclaims grouped by the instance that was lost, most first, then one
 * "Other" row folding the tail when it holds two or more pools. An episode without an old_instance record
 * is a reclaim of an unknown pool, not a missing one.
 */
export function poolTable(episodes: Episode[], limit = POOL_ROWS): PoolRow[] {
  const ranked = poolGroups(episodes)
    .map((group) => ({ group, row: poolRow(group.type, group.az, group.episodes) }))
    .sort((a, b) => b.row.reclaims - a.row.reclaims || (a.row.last < b.row.last ? 1 : -1));
  if (ranked.length <= limit) return ranked.map((r) => r.row);
  const head = ranked.slice(0, limit).map((r) => r.row);
  const tail = ranked.slice(limit);
  const [only] = tail;
  if (only && tail.length === 1) return [...head, only.row];
  return [
    ...head,
    poolRow(
      'Other',
      '',
      tail.flatMap((r) => r.group.episodes),
    ),
  ];
}
