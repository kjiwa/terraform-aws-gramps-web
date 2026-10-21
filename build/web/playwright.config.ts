import { defineConfig, devices } from '@playwright/test';

// Each spec starts its own ephemeral server (tests/support/server.ts, port
// 0) via the startStatus fixture in tests/e2e/fixtures.ts -- no global
// `webServer` here, which is what lets fullyParallel stay honest instead of
// every test racing a shared server's toggle set.
export default defineConfig({
  testDir: 'tests/e2e',
  globalSetup: './tests/support/build-error-pages.ts',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [['github'], ['html', { open: 'never' }]] : 'list',
  use: {
    trace: 'on-first-retry',
    // No pixel snapshots gate this suite -- macOS and ubuntu-latest
    // rasterize differently, so toHaveScreenshot() would be permanently
    // red on whichever platform didn't generate the baseline. Screenshots
    // still attach to a failing test's report for a human to look at.
    screenshot: 'only-on-failure',
    locale: 'en-US',
    timezoneId: 'UTC',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
});
