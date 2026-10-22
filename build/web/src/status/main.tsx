/**
 * Status page entry: theme sync at module top level (matching build/web/
 * src/error/main.ts's module-top-level-sync-then-DOMContentLoaded-mount
 * idiom), extended from that placeholder's data-theme-only version to also
 * set --gw-secondary/--gw-on-secondary. The Lambda-rendered version of this
 * sync (build/shared/theme-sync.js, spliced in by main.tf at zip time) reads
 * a runtime-injected `window.GwTheme` because the Lambda has no build step
 * of its own; this page does, so it imports src/shared/theme.ts's identical
 * functions directly -- no runtime indirection, no `if (!window.GwTheme)
 * return` guard needed, since the import is always present.
 *
 * Deliberately NOT error/main.ts's isDark()+matchMedia()-resolved version:
 * that always sets data-theme, for "system" too, which only works there
 * because pages/errors/shell.html's own default ("light") is always
 * overwritten before paint regardless of mode. This page only ever sets
 * data-theme for an *explicit* dark/light choice and leaves "system" alone
 * entirely, relying on status.css's `@media(prefers-color-scheme)` rule to
 * do the right thing on its own -- which requires pages/status.html's
 * <html> tag to ship with no data-theme attribute at all (see that file),
 * not a "light" default. Porting the matchMedia-resolved version here would
 * both diverge from that behavior and call an API jsdom doesn't implement
 * (confirmed by running the built page in jsdom: `window.matchMedia is not
 * a function`, thrown at module top level, silently killing the entire
 * inline script before anything else in it -- including the
 * DOMContentLoaded mount -- ever ran).
 */
import { options, render } from 'preact';
import { onColor, themeMode, treeColors } from '../shared/theme';
import { App } from './App';

// Runs synchronously, at module top level, before the stylesheet below this
// script tag is parsed -- see error/main.ts's comment on why that ordering
// matters (avoiding a dark-mode flash). 'system' sets no attribute at all:
// the @media(prefers-color-scheme) rule already covers that case on its
// own, so only an explicit choice needs a JS-set attribute to override
// what the OS would pick.
const mode = themeMode();
if (mode === 'dark' || mode === 'light') {
  document.documentElement.setAttribute('data-theme', mode);
}

const secondary = treeColors().secondary;
const rootStyle = document.documentElement.style;
rootStyle.setProperty('--gw-secondary', secondary);
rootStyle.setProperty('--gw-on-secondary', onColor(secondary));

/**
 * terraform/modules/edge's aws_s3_object.status_config writes `_status/
 * config.js` as `window.gwConfig = {disabledPanels: [...]}`, loaded via a
 * plain parser-blocking `<script src="/_status/config.js">` before this
 * bundle -- see status.css's data-disabled-panels rules, which this
 * attribute drives. Optional-chained regardless: still valid standalone if
 * that object is ever missing (a fresh, not-yet-deployed stack).
 */
declare global {
  interface Window {
    gwConfig?: { disabledPanels?: string[] };
  }
}

// Read and applied before the stylesheet below is parsed, same ordering
// reason as the theme sync above: a disabled panel's skeleton must never
// flash into view only to be hidden a frame later.
//
// Unlike status.py's old server-injected panel-flags CSS, this only takes
// effect when a script actually runs -- a visitor with JavaScript disabled
// never executes this bundle (inline or not), so a disabled panel's
// skeleton stays visible indefinitely instead of being hidden. Accepted:
// the static shell is a single build-time object shared by every
// deployment, so there is no server-side templating left to inject
// per-deployment CSS into it without JS: reproducing the old guarantee
// would need edge compute (a CloudFront Function reading a KeyValueStore)
// keyed on the same config, not a client-side fix.
const disabledPanels = window.gwConfig?.disabledPanels;
if (disabledPanels && disabledPanels.length) {
  document.documentElement.dataset.disabledPanels = disabledPanels.join(' ');
}

// Preact batches a setState-triggered re-render to a microtask by default.
// The original status.html mutated the DOM synchronously inside every
// click handler (plain imperative rebuilds, no scheduler at all), and
// status-interaction.test.ts asserts DOM state immediately after a real
// .click() with no intervening await -- so a microtask-deferred render would
// desync a real click from its visible effect, breaking that test (and, just
// as much, a real user's toggle click) even though the port is otherwise
// correct. Forcing every render synchronous restores the original's own
// behavior exactly, at the cost of (never in practice, on a page this small)
// potentially re-rendering more than a batched scheduler would coalesce.
options.debounceRendering = (cb: () => void) => cb();

document.addEventListener('DOMContentLoaded', () => {
  const panelsRoot = document.getElementById('panels');
  if (panelsRoot) render(<App />, panelsRoot);
});
