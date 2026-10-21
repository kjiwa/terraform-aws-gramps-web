/**
 * Storage's byte-path chart: wired identically to Host's CPU/memory chart
 * (same LineChart + RangeSelector + Inspector, see status-inspector.spec.ts's
 * header comment for why this needs real Chromium rather than jsdom), so this
 * covers the same three interaction surfaces -- mouse, page.touchscreen,
 * keyboard -- rather than duplicating Reliability's coverage of the mechanism
 * itself. Also proves the other path: with no byte series in the payload (the
 * default configuration), the card falls back to the percent meter and never
 * renders a chart.
 */
import type { Page } from '@playwright/test';
import type { GETStatusDataResponse } from '../../src/generated/status-payload.d.ts';
import { diskResizePayload, diskZeroTotalPayload, percentDiskPayload } from '../support/payload.ts';
import { ALL_TOGGLES_ON } from '../support/shell.ts';
import { expect, test, type StartStatusOptions } from './fixtures.ts';

const VIEWPORTS = [
  { width: 393, height: 900 },
  { width: 1440, height: 1000 },
];
const THEMES = ['light', 'dark'] as const;

async function gotoStatus(
  page: Page,
  startStatus: (opts: StartStatusOptions) => Promise<string>,
  theme: string,
  body?: GETStatusDataResponse,
) {
  const baseURL = await startStatus({
    server: {
      toggles: ALL_TOGGLES_ON,
      ...(body ? { dataOverride: { status: 200, body } } : {}),
    },
    tokens: { access: 'e2e-access-token' },
    localStorage: { grampsjs_settings: JSON.stringify({ theme }) },
  });
  await page.goto(`${baseURL}/_status`);
  await expect(page.locator('.card > h3').first()).toBeVisible();
}

// Not { hasText: 'Storage' }: Cost's breakdown renders "Amazon Simple
// Storage Service" as a line item whenever the fixture's cost panel is on,
// which the substring match picks up as a false positive alongside the
// real Storage card -- an exact heading match is the only unambiguous
// selector once both panels are on the page together.
function storageCard(page: Page) {
  return page
    .locator('.card')
    .filter({ has: page.getByRole('heading', { name: 'Storage', exact: true }) });
}

for (const viewport of VIEWPORTS) {
  for (const theme of THEMES) {
    test(`byte path: chart scrub via mouse and keyboard at ${viewport.width}px, ${theme} theme`, async ({
      page,
      startStatus,
    }) => {
      await page.setViewportSize(viewport);
      await gotoStatus(page, startStatus, theme);

      const card = storageCard(page);
      const svg = card.locator('.chart svg');
      const chartScrub = card.locator('.chart-scrub');
      await expect(svg).toBeVisible();
      await expect(chartScrub).toBeVisible();
      await expect(svg.locator('line[stroke-dasharray]')).toHaveCount(0);

      // Percent-of-capacity axis: fixed 0/50/100 ticks, not an auto-scaled
      // byte range -- see the parent plan's "mirror Host.tsx" change.
      const tickTexts = await svg.locator('text').allTextContents();
      expect(tickTexts).toEqual(expect.arrayContaining(['0%', '50%', '100%']));

      // Storage sits well below the fold (unlike Reliability, the first
      // card) -- page.mouse.move uses raw viewport coordinates and, unlike
      // locator.click()/hover(), never scrolls the target into view itself.
      await chartScrub.scrollIntoViewIfNeeded();
      const box = await chartScrub.boundingBox();
      if (!box) throw new Error('status-storage-chart: chart scrub overlay has no bounding box');
      await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
      await expect(svg.locator('line[stroke-dasharray]')).toHaveCount(1);
      const readout = card.locator('.chart-key');
      // Percent first, byte total in parentheses -- see keyItems() in
      // Storage.tsx.
      await expect(readout).toHaveText(/data \d+\.\d% \([\d.]+ [KMGT]?i?B\)/);
      await expect(readout).toHaveText(/root \d+\.\d% \([\d.]+ [KMGT]?i?B\)/);

      await page.mouse.move(box.x, box.y - 50);
      await expect(svg.locator('line[stroke-dasharray]')).toHaveCount(0);

      // Keyboard: Home/End move the scrub to the first/last sample.
      await chartScrub.focus();
      await chartScrub.press('Home');
      await expect(chartScrub).toHaveAttribute('aria-valuenow', '0');
      await chartScrub.press('End');
      const max = await chartScrub.getAttribute('aria-valuemax');
      await expect(chartScrub).toHaveAttribute('aria-valuenow', max ?? '');
    });
  }
}

test.describe('touch', () => {
  test.use({ hasTouch: true });

  test('byte path: a tap on the chart scrub pins a value', async ({ page, startStatus }) => {
    await page.setViewportSize({ width: 393, height: 900 });
    await gotoStatus(page, startStatus, 'light');

    const chartScrub = storageCard(page).locator('.chart-scrub');
    await chartScrub.scrollIntoViewIfNeeded();
    const box = await chartScrub.boundingBox();
    if (!box) throw new Error('status-storage-chart: chart scrub overlay has no bounding box');

    await page.touchscreen.tap(box.x + box.width * 0.25, box.y + box.height / 2);
    await expect(chartScrub).toHaveAttribute('aria-valuenow', /^\d+$/);
    const first = await chartScrub.getAttribute('aria-valuenow');

    await page.touchscreen.tap(box.x + box.width * 0.75, box.y + box.height / 2);
    const second = await chartScrub.getAttribute('aria-valuenow');
    expect(second).not.toBe(first);
  });
});

test('percent path: no byte series in the payload falls back to the disk-used meter, no chart', async ({
  page,
  startStatus,
}) => {
  await gotoStatus(page, startStatus, 'light', percentDiskPayload());

  const card = storageCard(page);
  await expect(card.locator('.chart')).toHaveCount(0);
  await expect(card.locator('.meter')).toBeVisible();
  await expect(card.locator('.note', { hasText: 'Disk used:' })).toBeVisible();
});

test('byte path: a mid-range volume resize renders a real chart with no page errors', async ({
  page,
  startStatus,
}) => {
  const pageErrors: Error[] = [];
  page.on('pageerror', (err) => pageErrors.push(err));

  await gotoStatus(page, startStatus, 'light', diskResizePayload());

  const svg = storageCard(page).locator('.chart svg');
  await expect(svg).toBeVisible();
  // A resize halves/doubles the per-cell percent (see diskResizePayload());
  // proving the chart draws more than one polyline segment for the data
  // series is what shows the step actually rendered rather than being
  // averaged or clamped away.
  await expect(svg.locator('polyline')).not.toHaveCount(0);
  expect(pageErrors).toEqual([]);
});

test('byte path: a zeroed total cell renders a gap, no NaN/Infinity on the page', async ({
  page,
  startStatus,
}) => {
  const pageErrors: Error[] = [];
  page.on('pageerror', (err) => pageErrors.push(err));

  await gotoStatus(page, startStatus, 'light', diskZeroTotalPayload());

  const svg = storageCard(page).locator('.chart svg');
  await expect(svg).toBeVisible();
  const svgHtml = await svg.evaluate((el) => el.outerHTML);
  expect(svgHtml).not.toContain('NaN');
  expect(svgHtml).not.toContain('Infinity');
  expect(pageErrors).toEqual([]);
});
