/**
 * Error page client script: theme application, then the auto-retry
 * countdown. Bundled as an ES module by Vite/vite-plugin-singlefile and
 * downgraded to a plain blocking <script> by gwFinalize (vite/finalize.ts)
 * at build time -- a deferred module script would run after the stylesheet
 * paints, reintroducing the dark-mode flash this ordering exists to avoid.
 * See pages/errors/shell.html for why this tag precedes the stylesheet
 * link in document order.
 */
import { isDark, themeMode } from '../shared/theme';
import { contextLine } from './context';

const CONTEXT_TIMEOUT_MS = 4000;

// Runs synchronously, at module top level, before the stylesheet below this
// script tag is parsed.
document.documentElement.setAttribute(
  'data-theme',
  isDark(themeMode(), window.matchMedia('(prefers-color-scheme: dark)').matches) ? 'dark' : 'light',
);

/**
 * Progressive enhancement: any failure (network, timeout, non-200, non-JSON,
 * unexpected shape) leaves the reserved line empty. Never touches the
 * countdown or the retry button.
 */
async function showContext(el: HTMLElement): Promise<void> {
  const ctl = new AbortController();
  const timer = window.setTimeout(() => ctl.abort(), CONTEXT_TIMEOUT_MS);
  try {
    const r = await fetch('/_status/public', {
      headers: { Accept: 'application/json' },
      signal: ctl.signal,
    });
    if (r.status !== 200) return;
    // The server's clock, not the visitor's, anchors the 30-day window.
    const now = Date.parse(r.headers.get('Date') ?? '');
    if (Number.isNaN(now)) return;
    const line = contextLine(await r.json(), now);
    if (line) el.textContent = line;
  } catch {
    // Left empty by design.
  } finally {
    window.clearTimeout(timer);
  }
}

// The countdown element doesn't exist yet when this module evaluates (the
// script runs in <head>, before <body> is parsed), so its setup waits for
// the DOM rather than running inline like the theme line above.
document.addEventListener('DOMContentLoaded', () => {
  const ctx = document.getElementById('ctx');
  if (ctx) void showContext(ctx);
  const el = document.getElementById('cd');
  if (!el) return;
  let n = 10;
  const iv = window.setInterval(() => {
    n -= 1;
    if (n <= 0) {
      window.clearInterval(iv);
      location.reload();
      return;
    }
    el.textContent = String(n);
  }, 1000);
});
