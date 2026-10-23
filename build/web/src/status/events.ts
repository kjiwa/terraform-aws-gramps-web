import type { Episode, ReliabilityCell } from '../generated/status-payload';
import { fmtDuration } from '../shared/format';
import { CAUSE_CLASSES, causeClass } from './causes';
import { cellOf, type Grid } from './ranges';

export interface StripWindow {
  startMs: number;
  cellMs: number;
}

const LABEL_RE = /^(\d{4}-\d{2}-\d{2})(?: (\d{2}:\d{2}))?/;
const NAMED_INCIDENTS = 3;

/**
 * The strip's own time axis, recovered from its cells: the first cell's
 * server label names its start (UTC, in all three label formats; see
 * cell_label() in lambda/status.py) and the cells tile `cell_s` each, so a
 * pan needs no extra data. null when the label does not parse.
 */
export function stripWindow(cells: ReliabilityCell[], cellS: number): StripWindow | null {
  const m = LABEL_RE.exec(cells[0]?.label ?? '');
  if (!m) return null;
  const startMs = Date.parse(`${m[1]}T${m[2] ?? '00:00'}:00Z`);
  if (Number.isNaN(startMs)) return null;
  return { startMs, cellMs: cellS * 1000 };
}

/** Episodes overlapping cell `index`, so one that began earlier or runs later still marks it. */
export function cellIncidents(w: StripWindow, index: number, episodes: Episode[]): Episode[] {
  const from = w.startMs + index * w.cellMs;
  const to = from + w.cellMs;
  return episodes.filter((ep) => {
    const started = Date.parse(ep.started);
    return started < to && started + ep.duration_s * 1000 >= from;
  });
}

/** "2 incidents: spot-reclaim 5m 0s, deploy 1m 0s"; the first few named, the rest counted. */
export function incidentsText(episodes: Episode[]): string {
  if (episodes.length === 0) return '';
  const named = episodes
    .slice(0, NAMED_INCIDENTS)
    .map((ep) => `${ep.cause} ${fmtDuration(ep.duration_s)}`);
  const rest = episodes.length - named.length;
  if (rest > 0) named.push(`+${rest} more`);
  return `${episodes.length} incident${episodes.length === 1 ? '' : 's'}: ${named.join(', ')}`;
}

/** Per cell of `grid`, episode counts by cause class in CAUSE_CLASSES order; episodes outside the grid are dropped. */
export function incidentCounts(grid: Grid, episodes: Episode[]): number[][] {
  const counts = Array.from({ length: grid.count }, () => CAUSE_CLASSES.map(() => 0));
  episodes.forEach((ep) => {
    const cell = counts[cellOf(grid, Date.parse(ep.started))];
    const slot = CAUSE_CLASSES.findIndex((c) => c.id === causeClass(ep));
    if (cell) cell[slot] = (cell[slot] ?? 0) + 1;
  });
  return counts;
}

const DAY_MS = 86400 * 1000;

const isoDate = (ms: number) => new Date(ms).toISOString().slice(0, 10);
const isoHour = (ms: number) => new Date(ms).toISOString().slice(0, 13).replace('T', ' ') + ':00';

/** Tooltip title and short axis label of cell `index`, in UTC like every other time on the page. */
export function cellLabel(grid: Grid, index: number): { title: string; label: string } {
  const start = grid.startMs + index * grid.cellMs;
  if (grid.cellMs < DAY_MS) {
    return { title: `${isoHour(start)} UTC`, label: isoHour(start).slice(5) };
  }
  if (grid.cellMs === DAY_MS) return { title: isoDate(start), label: isoDate(start).slice(5) };
  const last = isoDate(start + grid.cellMs - DAY_MS);
  return { title: `${isoDate(start)} – ${last}`, label: isoDate(start).slice(5) };
}
