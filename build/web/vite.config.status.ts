import { defineConfig } from 'vite';
import { makeConfig } from './vite.shared.ts';

// src="/_status/config.js": the parser-blocking per-deployment config tag,
// which must survive the build untouched (see src/status/main.tsx).
// #skeleton: the static pre-fetch markup a script-throw or JS-disabled
// visitor still sees (status-skeleton.spec.ts). #panels: the Preact mount
// root (sibling of #skeleton, never nested).
export default defineConfig(
  makeConfig('pages/status.html', ['src="/_status/config.js"', 'id="skeleton"', 'id="panels"']),
);
