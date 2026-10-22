/**
 * The one Playwright fixture every spec in this directory uses: starts a
 * fresh tests/support/server.ts per test (no global `webServer`, so
 * `fullyParallel` stays honest -- each test owns its own toggle set and
 * override responses without racing another test's server) and seeds
 * localStorage/the page clock before the first navigation.
 */
import { test as base } from '@playwright/test';
import { startStatusServer, type RunningServer, type ServerOptions } from '../support/server.ts';

export interface StatusTokens {
  access?: string;
  refresh?: string;
}

export interface StartStatusOptions {
  server: ServerOptions;
  tokens?: StatusTokens;
  /** Arbitrary extra localStorage entries, seeded before navigation (e.g. grampsjs_settings for a theme test). */
  localStorage?: Record<string, string>;
}

interface StatusFixtures {
  /** Starts the ephemeral server and returns its base URL; call `page.goto(\`${url}/_status\`)` next. */
  startStatus: (opts: StartStatusOptions) => Promise<string>;
}

// Every test's page clock freezes here -- see tests/support/mount.ts's
// FROZEN_NOW_ISO for why (only the Cost panel reads the wall clock at all)
// and for why the two suites share the instant, though nothing requires
// them to agree.
const FROZEN_NOW = new Date('2026-06-15T12:00:00Z');

export const test = base.extend<StatusFixtures>({
  startStatus: async ({ page, context }, use) => {
    let server: RunningServer | undefined;

    await use(async (opts: StartStatusOptions) => {
      server = await startStatusServer(opts.server);

      const seeds: Record<string, string> = { ...opts.localStorage };
      if (opts.tokens?.access) seeds.access_token = opts.tokens.access;
      if (opts.tokens?.refresh) seeds.refresh_token = opts.tokens.refresh;
      if (Object.keys(seeds).length > 0) {
        await context.addInitScript((entries: Record<string, string>) => {
          for (const [key, value] of Object.entries(entries))
            window.localStorage.setItem(key, value);
        }, seeds);
      }

      // Must precede navigation: the clock has to be frozen before the
      // page's own scripts (including the Cost panel's `new Date()` call)
      // ever run.
      await page.clock.setFixedTime(FROZEN_NOW);

      return server.url;
    });

    await server?.close();
  },
});

export { expect } from '@playwright/test';
