/**
 * Cross product of the three viewport widths this page's CSS actually
 * branches on (320px: below the 40rem dl.kv breakpoint; 768/1440px:
 * above it) and both explicit themes. No pixel snapshots (see
 * playwright.config.ts's comment) -- these are structural assertions: no
 * horizontal overflow anywhere on the page, data-theme follows
 * localStorage, and the strip stays overflow-free even at its widest
 * (the 90-cell range, the worst case for `.strip`'s flex-shrink layout).
 */
import { ALL_TOGGLES_ON } from '../support/shell.ts';
import { expect, test } from './fixtures.ts';

const VIEWPORTS = [
  { width: 320, height: 800 },
  { width: 768, height: 1000 },
  { width: 1440, height: 1000 },
];

const THEMES = ['light', 'dark'] as const;

for (const viewport of VIEWPORTS) {
  for (const themeName of THEMES) {
    test(`no horizontal overflow at ${viewport.width}px, ${themeName} theme`, async ({
      page,
      startStatus,
    }) => {
      await page.setViewportSize(viewport);
      const baseURL = await startStatus({
        server: { toggles: ALL_TOGGLES_ON },
        tokens: { access: 'e2e-access-token' },
        localStorage: { grampsjs_settings: JSON.stringify({ theme: themeName }) },
      });
      await page.goto(`${baseURL}/_status`);
      await expect(page.locator('.card > h3').first()).toBeVisible();

      await expect(page.locator('html')).toHaveAttribute('data-theme', themeName);

      const overflow = await page.evaluate(() => {
        const el = document.scrollingElement ?? document.documentElement;
        return { scrollWidth: el.scrollWidth, clientWidth: el.clientWidth };
      });
      expect(overflow.scrollWidth).toBeLessThanOrEqual(overflow.clientWidth + 1);

      // Switch the Reliability strip to its widest range (90 cells) --
      // still flex-shrink, not flex-wrap (see .strip's CSS), so this is
      // the layout's actual worst case for horizontal overflow, not a
      // theoretical one.
      await page
        .locator('.card', { hasText: 'Reliability' })
        .getByRole('button', { name: '90d', exact: true })
        .click();
      await expect(
        page.locator('.card', { hasText: 'Reliability' }).locator('.strip > div'),
      ).toHaveCount(90);

      const overflowAt90d = await page.evaluate(() => {
        const el = document.scrollingElement ?? document.documentElement;
        return { scrollWidth: el.scrollWidth, clientWidth: el.clientWidth };
      });
      expect(overflowAt90d.scrollWidth).toBeLessThanOrEqual(overflowAt90d.clientWidth + 1);
    });
  }
}

test('Incidents table causes no page overflow at 320px once opened', async ({
  page,
  startStatus,
}) => {
  // The <details> disclosure is closed by default, so the loop above never
  // actually lays out this table -- the Ended and Instance columns widen it past
  // this viewport, so this is the specific case the page-wide check above can't
  // see without opening it first. This ensures the table stays inside
  // .table-scroll's overflow-x: auto.
  await page.setViewportSize({ width: 320, height: 800 });
  const baseURL = await startStatus({
    server: { toggles: ALL_TOGGLES_ON },
    tokens: { access: 'e2e-access-token' },
  });
  await page.goto(`${baseURL}/_status`);
  await page
    .locator('.card', { has: page.locator('h3', { hasText: /^Incidents$/ }) })
    .locator('summary')
    .first()
    .click();
  await expect(
    page
      .locator('.card', { has: page.locator('h3', { hasText: /^Incidents$/ }) })
      .locator('.table-scroll table')
      .first(),
  ).toBeVisible();

  const overflow = await page.evaluate(() => {
    const el = document.scrollingElement ?? document.documentElement;
    return { scrollWidth: el.scrollWidth, clientWidth: el.clientWidth };
  });
  expect(overflow.scrollWidth).toBeLessThanOrEqual(overflow.clientWidth + 1);
});
