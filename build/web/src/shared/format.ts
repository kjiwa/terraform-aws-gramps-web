/**
 * Formatting helpers shared across status panel components. Pure functions,
 * no DOM -- behavior (rounding, unit thresholds, string shape) must match
 * exactly what tests/unit/status-render.test.ts's snapshot oracle expects.
 */

/**
 * decimals defaults to 2 so most callers (the latency legend) are
 * unaffected; the reliability tiles pass the server's single
 * UPTIME_DECIMALS value (d.decimals in status.py's reliability() payload),
 * and the host CPU/memory chart key passes 1.
 */
export function fmtPct(n: number | null | undefined, decimals?: number): string {
  if (n === null || n === undefined) return '—';
  return n.toFixed(decimals === undefined ? 2 : decimals) + '%';
}

/**
 * fmtPct's default toFixed(2) would print "99.90%"/"95.00%" for the
 * legend's thresholds, so this trims trailing zeros instead.
 */
export function fmtThreshold(t: number): string {
  return (t * 100).toFixed(3).replace(/\.?0+$/, '') + '%';
}

export function fmtDuration(s: number | null | undefined): string {
  if (s === null || s === undefined) return '—';
  const rounded = Math.max(0, Math.round(s));
  const h = Math.floor(rounded / 3600);
  const m = Math.floor((rounded % 3600) / 60);
  const sec = rounded % 60;
  if (h >= 48) return Math.floor(h / 24) + 'd ' + (h % 24) + 'h';
  if (h) return h + 'h ' + m + 'm';
  if (m) return m + 'm ' + sec + 's';
  return sec + 's';
}

/** Binary units (KiB/MiB/GiB/TiB): the division below is already by 1024,
 * matching what df and CloudWatch both report -- only the labels were
 * wrong. */
export function fmtBytes(n: number | null | undefined): string {
  if (n === null || n === undefined) return '—';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  let v = n;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return v.toFixed(i === 0 ? 0 : 1) + ' ' + units[i];
}

export function fmtUsd(n: number | null | undefined): string {
  return n === null || n === undefined ? '—' : '$' + n.toFixed(2);
}

export function fmtBool(v: boolean | null | undefined): string {
  return v === null || v === undefined ? '—' : v ? 'yes' : 'no';
}

/**
 * Explicit UTC, not toLocaleString(): every call site here feeds a
 * Z-suffixed timestamp from status.py's iso() helper, and the strip labels
 * elsewhere are UTC too -- leaving this at browser-local silently put
 * incident times in a different timezone from the strip they're meant to
 * line up against.
 */
export function fmtDate(iso: string | null | undefined): string {
  if (!iso) return '—';
  try {
    return new Date(iso).toISOString().slice(0, 19).replace('T', ' ') + ' UTC';
  } catch {
    return iso;
  }
}

/**
 * Table-cell form of fmtDate: "YYYY-MM-DD HH:MM", the column header says UTC
 * and the cell's own title carries fmtDate's full timestamp.
 */
export function fmtStamp(iso: string | null | undefined): string {
  return iso ? fmtDate(iso).slice(0, 16) : '—';
}

/** The date alone, "YYYY-MM-DD", for a cell where the time of day is only in its title. */
export function fmtDay(iso: string | null | undefined): string {
  return iso ? fmtDate(iso).slice(0, 10) : '—';
}

/**
 * toLocaleString(), not String(): these are token counts (tens of
 * thousands over a month), and a bare "78128" is slower to read at a
 * glance than "78,128" is.
 */
export function numOrDash(n: number | null | undefined): string {
  return n === null || n === undefined ? '—' : n.toLocaleString();
}

/**
 * Chart y-axis labels, not the stat-row totals above (those keep
 * toLocaleString()'s full-precision commas) -- a tick needs to stay short
 * enough not to crowd the plot. drawChart() always passes an already-
 * Math.round()'d integer, so no fractional input to handle.
 */
export function fmtCompact(n: number | null | undefined): string {
  if (n === null || n === undefined) return '—';
  if (n >= 1000000) return (n / 1000000).toFixed(1).replace(/\.0$/, '') + 'M';
  if (n >= 1000) return (n / 1000).toFixed(1).replace(/\.0$/, '') + 'k';
  return String(n);
}
