import type { Change, Episode, ReliabilityCell } from '../generated/status-payload';
import { fmtDate, fmtDuration } from '../shared/format';
import { causeClass, isDeliberateDeploy, type CauseClass } from './causes';

export interface LaneWindow {
  startMs: number;
  endMs: number;
}

export type LaneEvent =
  | { kind: 'episode'; at: string; cls: CauseClass; cause: string; durationS: number }
  | { kind: 'deploy'; at: string; outcome: string; durationS: number | null | undefined };

const LABEL_RE = /^(\d{4}-\d{2}-\d{2})(?: (\d{2}:\d{2}))?/;

/**
 * The strip's own time axis, recovered from its cells: the first cell's
 * server label names its start (UTC, in all three label formats; see
 * cell_label() in lambda/status.py) and the cells tile `cell_s` each, so a
 * pan needs no extra data. null when the label does not parse.
 */
export function laneWindow(cells: ReliabilityCell[], cellS: number): LaneWindow | null {
  const m = LABEL_RE.exec(cells[0]?.label ?? '');
  if (!m) return null;
  const startMs = Date.parse(`${m[1]}T${m[2] ?? '00:00'}:00Z`);
  if (Number.isNaN(startMs)) return null;
  return { startMs, endMs: startMs + cells.length * cellS * 1000 };
}

export function laneEvents(w: LaneWindow, episodes: Episode[], changes: Change[]): LaneEvent[] {
  const within = (iso: string) => {
    const t = Date.parse(iso);
    return t >= w.startMs && t < w.endMs;
  };
  // An episode that began earlier or runs later still marks the window.
  const overlaps = (ep: Episode) =>
    Date.parse(ep.started) < w.endMs && Date.parse(ep.started) + ep.duration_s * 1000 >= w.startMs;
  const marks: LaneEvent[] = [
    ...episodes.filter(overlaps).map((ep): LaneEvent => ({
      kind: 'episode',
      at: ep.started,
      cls: causeClass(ep),
      cause: ep.cause,
      durationS: ep.duration_s,
    })),
    ...changes
      .filter((c) => isDeliberateDeploy(c) && within(c.at))
      .map((c): LaneEvent => ({
        kind: 'deploy',
        at: c.at,
        outcome: c.outcome,
        durationS: c.duration_s,
      })),
  ];
  return marks.sort((a, b) => (a.at < b.at ? -1 : 1));
}

/** Position of an instant on the lane, as a percentage of the window. */
export function lanePercent(w: LaneWindow, iso: string): number {
  return ((Date.parse(iso) - w.startMs) / (w.endMs - w.startMs)) * 100;
}

/** An episode's left edge and width on the lane, clamped to 0-100%. */
export function laneSpan(
  w: LaneWindow,
  iso: string,
  durationS: number,
): { left: number; width: number } {
  const span = w.endMs - w.startMs;
  const start = Math.max(Date.parse(iso), w.startMs);
  const end = Math.min(Date.parse(iso) + durationS * 1000, w.endMs);
  return {
    left: ((start - w.startMs) / span) * 100,
    width: (Math.max(0, end - start) / span) * 100,
  };
}

/** The readout text for a lane mark: time, cause or deploy outcome, duration. */
export function describeEvent(e: LaneEvent): string {
  if (e.kind === 'deploy') {
    return `${fmtDate(e.at)} · deploy ${e.outcome.replace('-', ' ')}${
      e.durationS == null ? '' : ` · ${fmtDuration(e.durationS)}`
    }`;
  }
  return `${fmtDate(e.at)} · ${e.cause} · ${fmtDuration(e.durationS)} down`;
}
