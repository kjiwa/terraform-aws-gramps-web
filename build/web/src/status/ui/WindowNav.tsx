import { useState } from 'preact/hooks';
import { fmtDate } from '../../shared/format';
import { RANGE_SPAN_S, type RangeKey } from '../ranges';

// CloudWatch's own retention ceiling for hourly-and-coarser rollups --
// status.py's SERIES_MAX_AGE_DAYS, mirrored here the same way ranges.ts
// already mirrors RANGES: this file stays ignorant of *why* 455, only of
// the clamp `end` must respect, and the server is the one that actually
// enforces it. A surface with a shorter history passes its own maxAgeDays.
const SERIES_MAX_AGE_DAYS = 455;

/**
 * ◀ / ▶ / Now, plus the panned window's own label -- rendered next to a
 * surface's RangeSelector inside .range-scope. One click moves a full window
 * (`range`'s own span, from ranges.ts's RANGE_SPAN_S): ◀ disabled once a
 * further pan would pass the 455-day clamp (or `maxAgeDays`), ▶ disabled at the live edge
 * (`end === null`) and clamped back to it rather than allowed to overshoot
 * into the future.
 *
 * The label reads `echoedEnd` -- the server's own echoed /_status/series
 * `end` (see series.ts's useSeries()), not `end` itself -- no client clock
 * math beyond formatting it. At rest (`echoedEnd === null`) it reads
 * "Live".
 */
export function WindowNav({
  range,
  end,
  echoedEnd,
  onChange,
  maxAgeDays = SERIES_MAX_AGE_DAYS,
}: {
  range: RangeKey;
  end: string | null;
  echoedEnd: string | null;
  onChange: (end: string | null) => void;
  maxAgeDays?: number;
}) {
  // Date.now() can't be called during render (react-hooks/purity); a lazy
  // useState reads it once, at mount, which is fine here -- both uses below
  // (the 455-day clamp and the live-edge position) tolerate staleness on the
  // order of a session. forward() re-reads the real clock since it's an
  // event handler, not render.
  const [mountedAtMs] = useState(() => Date.now());
  const spanMs = RANGE_SPAN_S[range] * 1000;
  const currentMs = end === null ? mountedAtMs : new Date(end).getTime();
  const earliestMs = mountedAtMs - maxAgeDays * 86400 * 1000;

  const canBack = currentMs - spanMs >= earliestMs;
  const canForward = end !== null;

  function back(): void {
    if (!canBack) return;
    onChange(new Date(currentMs - spanMs).toISOString());
  }
  function forward(): void {
    if (!canForward) return;
    const nowMs = Date.now();
    const nextMs = currentMs + spanMs;
    onChange(nextMs >= nowMs ? null : new Date(nextMs).toISOString());
  }

  return (
    <div class="window-nav" role="group" aria-label="Pan time window">
      <button type="button" onClick={back} disabled={!canBack} aria-label="Earlier window">
        ◀
      </button>
      <span aria-live="polite">{echoedEnd ? fmtDate(echoedEnd) : 'Live'}</span>
      <button type="button" onClick={forward} disabled={!canForward} aria-label="Later window">
        ▶
      </button>
      <button type="button" onClick={() => onChange(null)} disabled={end === null}>
        Now
      </button>
    </div>
  );
}
