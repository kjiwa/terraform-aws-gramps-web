import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { defineConfig } from 'vite';
import { makeConfig } from './vite.shared.ts';
import { ERROR_PAGES, STATUS_PUBLIC_PAGE, TITLE } from './src/error/pages.ts';
import { renderErrorPage } from './src/error/render.ts';

/**
 * Builds exactly ONE of the three error pages per invocation, selected by
 * GW_ERROR_CODE -- see package.json's build:error script, which loops this
 * over 502/503/504. A single Rollup/Rolldown build config can't produce all
 * three: vite-plugin-singlefile's recommended config sets
 * output.codeSplitting = false under Vite 8 (the Rolldown-backed Vite
 * major), which Rolldown rejects outright for a multi-entry input --
 * "multiple inputs are not supported when output.codeSplitting is false."
 * Running three single-entry builds sidesteps that restriction and keeps
 * every entry's bundle self-contained, which is what lets
 * vite-plugin-singlefile's src-tag inlining (see its generateBundle) catch
 * everything with nothing left importing a chunk that gets deleted out from
 * under it.
 *
 * The page itself is materialized from one shared shell
 * (pages/errors/shell.html) and src/error/pages.ts's per-code copy, at
 * config-eval time -- see this file's write below. Generated output,
 * gitignored like dist/, not hand-duplicated per-code source.
 */
const code = process.env.GW_ERROR_CODE;
if (code !== '502' && code !== '503' && code !== '504') {
  throw new Error('vite.config.error.ts requires GW_ERROR_CODE to be one of 502, 503, 504.');
}
const copy = ERROR_PAGES[code];

const shellPath = resolve(import.meta.dirname, 'pages/errors/shell.html');
const shell = readFileSync(shellPath, 'utf-8');
const generatedDir = resolve(import.meta.dirname, 'pages/errors/generated');
mkdirSync(generatedDir, { recursive: true });

const html = renderErrorPage(shell, code, copy, TITLE, STATUS_PUBLIC_PAGE);

if (html.includes('__GW_')) {
  throw new Error(
    `vite.config.error.ts: unsubstituted __GW_*__ token remains in the ${code} page.`,
  );
}

const entryPath = resolve(generatedDir, `${code}.html`);
writeFileSync(entryPath, html);

export default defineConfig(
  makeConfig(entryPath, [
    'id="cd"', // the countdown element the auto-retry script updates
    'class="retry"', // the manual retry button
    ...(STATUS_PUBLIC_PAGE ? ['id="ctx"'] : []), // the reserved measured-context line
  ]),
);
