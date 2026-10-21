import { useEffect, useRef, useState } from 'preact/hooks';
import type { PanelError } from '../generated/status-payload';
import type { GETStatusSeriesResponse } from '../generated/status-series';
import { fetchStatusJson } from './api';
import type { RangeKey } from './ranges';

export type SeriesPanel = 'reliability' | 'host_metrics' | 'assistant';

export interface SeriesState<T> {
  /** The panel subtree from the last successful fetch -- same shape as the
   * corresponding /_status/data key -- or null before the first one lands.
   * Every panel falls back to its own live prop when this is null, so a
   * resting/loading/error state never blanks a chart. */
  data: (T | PanelError) | null;
  /** The server's own echoed `end` from that same fetch -- what WindowNav's
   * label reads, not the `end` this hook was called with: the two agree in
   * practice, but the echo keeps the label's source of truth server-side. */
  end: string | null;
  loading: boolean;
  error: string | null;
}

const RESTING: SeriesState<never> = { data: null, end: null, loading: false, error: null };

/**
 * GET /_status/series for one panel/range/end. `end === null` is the resting
 * state: it issues no fetch at all, and every caller renders from its live
 * /_status/data props exactly as before panning existed. A pan keeps the
 * previous data/end visible (with `loading: true`) rather than clearing
 * them, so the panel can dim in place instead of blanking while the new
 * window loads.
 *
 * `T` is asserted by the caller from `panel` (e.g. `useSeries<HostMetrics>
 * ('host_metrics', ...)`) -- the server enforces the real correspondence;
 * this is the client-side type-level half of that contract.
 */
export function useSeries<T>(
  panel: SeriesPanel,
  range: RangeKey | undefined,
  end: string | null,
): SeriesState<T> {
  const [state, setState] = useState<SeriesState<T>>(RESTING);
  // main.tsx's options.debounceRendering = (cb) => cb() (synchronous
  // rendering, no batching -- see that file's comment) means a single
  // click can trigger a mid-render bailout elsewhere in the same component
  // (useResettableIndex's resetKey-changed correction) that re-invokes this
  // hook a second time before commit, with the identical (panel, range,
  // end) tuple -- this ref is a plain request-dedup guard against issuing
  // two /_status/series fetches for what is, from the caller's side, one
  // pan.
  const lastKeyRef = useRef<string | null>(null);

  useEffect(() => {
    if (end === null || !range) {
      setState(RESTING);
      lastKeyRef.current = null;
      return;
    }
    const requestKey = `${panel}:${range}:${end}`;
    if (lastKeyRef.current === requestKey) return;
    lastKeyRef.current = requestKey;

    let cancelled = false;
    setState((prev) => ({ ...prev, loading: true, error: null }));

    const qs = new URLSearchParams({ panel, range, end }).toString();
    void fetchStatusJson(`/_status/series?${qs}`)
      .then(async (r) => {
        if (cancelled) return;
        if (!r.ok) {
          const body = (await r.json().catch(() => ({}))) as { error?: string };
          setState((prev) => ({
            ...prev,
            loading: false,
            error: body.error || `HTTP ${r.status}`,
          }));
          return;
        }
        const body = (await r.json()) as GETStatusSeriesResponse;
        setState({ data: body.data as T | PanelError, end: body.end, loading: false, error: null });
      })
      .catch(() => {
        if (!cancelled) setState((prev) => ({ ...prev, loading: false, error: 'network error' }));
      });

    return () => {
      cancelled = true;
    };
  }, [panel, range, end]);

  return state;
}
