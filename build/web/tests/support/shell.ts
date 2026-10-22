/**
 * The one indirection point in this suite: everywhere else, tests are
 * written against rendered behavior (DOM, ARIA, fetch calls), never against
 * how the shell is delivered. This file is the sole exception, deliberately
 * so -- a test elsewhere needing an edit when the shell mechanism changes
 * would mean it was testing the mechanism instead of the behavior.
 *
 * Reads the real built `dist/pages/status.html` (theme-sync and
 * panel-flags are gone -- theme.ts is a plain import, and the four
 * data-disabled-panels CSS rules are static, see status.css) and splices in
 * a real `window.gwConfig = {...}` script ahead of the bundle, in place of
 * status.py's per-deployment CSS splice -- see main.tsx's own comment on
 * why that ordering (before the bundle's script, before the stylesheet)
 * matters: a disabled panel's skeleton must never flash into view only to
 * be hidden a frame later.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

// resolve(import.meta.dirname, ...) rather than `new URL(relative,
// import.meta.url)`: Vite statically rewrites that exact pattern into a
// dev-server asset URL (`http://localhost:.../@fs/...`) whenever the
// relative path climbs outside the project root, which this path does --
// fileURLToPath() on the rewritten result throws "URL must be of scheme
// file". import.meta.dirname is a plain string, so it isn't a candidate
// for that transform.
const STATUS_HTML_PATH = resolve(import.meta.dirname, '../../dist/pages/status.html');

/** The five deployment-config toggles status.py's env vars drive. */
export interface Toggles {
  host_metrics: boolean;
  cost: boolean;
  backups: boolean;
  assistant: boolean;
  public_reliability: boolean;
}

export const ALL_TOGGLES_ON: Toggles = {
  host_metrics: true,
  cost: true,
  backups: true,
  assistant: true,
  public_reliability: true,
};

export const ALL_TOGGLES_OFF: Toggles = {
  host_metrics: false,
  cost: false,
  backups: false,
  assistant: false,
  public_reliability: false,
};

/**
 * The four toggles that gate a `[data-panel]` section -- collect_status()'s
 * branch toggles. public_reliability is deliberately absent: it changes
 * route availability, not which panel markup the static skeleton hides.
 */
export const PANEL_TOGGLE_KEYS = ['backups', 'assistant', 'cost', 'host_metrics'] as const;

export function disabledPanels(t: Toggles): string[] {
  return PANEL_TOGGLE_KEYS.filter((key) => !t[key]);
}

/**
 * A real `window.gwConfig = {...}` script tag, matching what `_status/config.js`
 * serves, reproduced inline here so a test can control it per-toggle-set without
 * a second HTTP route. See main.tsx's
 * `declare global { interface Window { gwConfig?: ... } }` for the shape this
 * must match.
 */
export function configScript(t: Toggles): string {
  const config = { disabledPanels: disabledPanels(t) };
  return `<script>window.gwConfig=${JSON.stringify(config)};</script>`;
}

// The bundle's own inlined script -- gwFinalize (vite/finalize.ts)
// downgrades it from type="module" to a plain blocking script, so it's the
// first non-src <script> tag in the built document; matches whether or not
// it still carries other attributes (there are none today, but this
// doesn't assume that stays true).
const BUNDLE_SCRIPT_RE = /<script(?![^>]*\bsrc=)[^>]*>/;

export interface ShellOptions {
  /** Whether to splice the inline configScript(t) in ahead of the bundle
   * script. Default true, for jsdom (mount.ts), which has no HTTP server to
   * serve the real `/_status/config.js` the built page now requests. The
   * Playwright server (tests/support/server.ts) passes false and serves that
   * route for real instead, so the suite exercises it rather than masking
   * it. */
  spliceConfig?: boolean;
}

/** Reads the real build output and, by default, injects a per-toggle-set
 * config script immediately before the bundle's own script tag, in document
 * order. */
export function shellHtml(t: Toggles, opts: ShellOptions = {}): string {
  const html = readFileSync(STATUS_HTML_PATH, 'utf-8');
  if (opts.spliceConfig === false) return html;
  if (!BUNDLE_SCRIPT_RE.test(html)) {
    throw new Error(
      'shellHtml: dist/pages/status.html has no inlined bundle <script> to inject window.gwConfig before -- run `npm run build:status` first.',
    );
  }
  return html.replace(BUNDLE_SCRIPT_RE, (match) => `${configScript(t)}${match}`);
}
