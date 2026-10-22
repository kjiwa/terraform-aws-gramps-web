const WINDOW_DAYS = 30;
const WINDOW_MS = WINDOW_DAYS * 24 * 60 * 60 * 1000;
const MIN_FOR_MEDIAN = 3;

/**
 * Durations (seconds) of the well-formed episodes that started inside the
 * window. Planned episodes count: visitors experience them as downtime.
 */
function recentDurations(incidents: unknown[], nowMs: number): number[] {
  const out: number[] = [];
  for (const e of incidents) {
    if (typeof e !== 'object' || e === null) continue;
    const { started, duration_s } = e as Record<string, unknown>;
    if (typeof started !== 'string' || typeof duration_s !== 'number') continue;
    if (!Number.isFinite(duration_s) || duration_s < 0) continue;
    const t = Date.parse(started);
    if (Number.isNaN(t) || t < nowMs - WINDOW_MS) continue;
    out.push(duration_s);
  }
  return out;
}

function median(values: number[]): number {
  const s = [...values].sort((a, b) => a - b);
  const mid = s.length >> 1;
  return s.length % 2 ? (s[mid] as number) : ((s[mid - 1] as number) + (s[mid] as number)) / 2;
}

function plural(n: number, unit: string): string {
  return `${n} ${unit}${n === 1 ? '' : 's'}`;
}

export function clearTime(seconds: number): string {
  const minutes = Math.max(1, Math.round(seconds / 60));
  if (minutes >= 48 * 60) return plural(Math.round(minutes / 1440), 'day');
  if (minutes < 60) return plural(minutes, 'minute');
  const rest = minutes % 60;
  return plural(Math.floor(minutes / 60), 'hour') + (rest ? ` ${plural(rest, 'minute')}` : '');
}

/**
 * The measured sentence for the error page, from a /_status/public payload.
 * Null when the payload is not the expected shape, so the caller renders nothing.
 */
export function contextLine(payload: unknown, nowMs: number): string | null {
  if (typeof payload !== 'object' || payload === null) return null;
  const { incidents } = payload as Record<string, unknown>;
  if (!Array.isArray(incidents)) return null;

  const durations = recentDurations(incidents, nowMs);
  const days = `the last ${WINDOW_DAYS} days`;
  if (durations.length === 0) return `No outages in ${days}.`;
  if (durations.length < MIN_FOR_MEDIAN)
    return `${plural(durations.length, 'earlier outage')} in ${days}.`;
  return `In ${days} this site had ${durations.length} outages. The median took ${clearTime(median(durations))} to clear.`;
}
