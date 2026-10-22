/**
 * Scrub inspector: the reliability strip's role="slider" and every
 * LineChart's own overlay (see src/status/inspect.ts). DOM/ARIA assertions
 * can't see real pointer geometry or a real touch tap, so this is
 * Playwright's job -- Vitest's coverage (status-inspect.test.ts) is limited
 * to the pure index math and the keyboard path, by measurement: jsdom's
 * Preact mount can't dispatch a pointer event Preact actually recognizes
 * (see that file's header comment).
 */
import type { Page } from '@playwright/test';
import { payloadFor } from '../support/payload.ts';
import { ALL_TOGGLES_ON } from '../support/shell.ts';
import { expect, test, type StartStatusOptions } from './fixtures.ts';

const VIEWPORTS = [
  { width: 393, height: 900 },
  { width: 1440, height: 1000 },
];
const THEMES = ['light', 'dark'] as const;

const payload = payloadFor(ALL_TOGGLES_ON);
const reliability = 'error' in payload.reliability ? undefined : payload.reliability;
const range30d = reliability?.ranges['30d'];
if (!range30d) throw new Error('status-inspector: fixture missing a 30d reliability range');
const cellCount = range30d.cells.length;

async function gotoStatus(
  page: Page,
  startStatus: (opts: StartStatusOptions) => Promise<string>,
  theme: string,
) {
  const baseURL = await startStatus({
    server: { toggles: ALL_TOGGLES_ON },
    tokens: { access: 'e2e-access-token' },
    localStorage: { grampsjs_settings: JSON.stringify({ theme }) },
  });
  await page.goto(`${baseURL}/_status`);
  await expect(page.locator('.card > h3').first()).toBeVisible();
}

for (const viewport of VIEWPORTS) {
  for (const theme of THEMES) {
    test(`strip inspector: hover, keyboard, and the readout at ${viewport.width}px, ${theme} theme`, async ({
      page,
      startStatus,
    }) => {
      await page.setViewportSize(viewport);
      await gotoStatus(page, startStatus, theme);

      const strip = page.locator('.card', { hasText: 'Reliability' }).locator('.strip');
      const readout = page.locator('.card', { hasText: 'Reliability' }).locator('.strip-key');

      // Resting: aria-valuenow is the last cell, matching Reliability.tsx's
      // resting-index contract.
      await expect(strip).toHaveAttribute('aria-valuenow', String(cellCount - 1));
      const restingText = await readout.textContent();
      expect(restingText).toContain(range30d.cells[cellCount - 1]?.label);

      // Hover at the first cell's own center -- the same ((i + 0.5) /
      // count) * w placement indexFromPointer inverts (see inspect.ts).
      const box = await strip.boundingBox();
      if (!box) throw new Error('status-inspector: strip has no bounding box');
      const firstCellX = box.x + box.width * (0.5 / cellCount);
      await page.mouse.move(firstCellX, box.y + box.height / 2);
      await expect(strip).toHaveAttribute('aria-valuenow', '0');
      await expect(readout).toContainText(range30d.cells[0]?.label ?? '');

      // Moving the mouse off the strip (a real "leave", not a touch's
      // implicit one) returns to resting.
      await page.mouse.move(box.x, box.y - 50);
      await expect(strip).toHaveAttribute('aria-valuenow', String(cellCount - 1));

      // Keyboard: focus, then Home/ArrowRight/End -- same contract as the
      // Vitest keyboard test, now against a real focused, real-layout page.
      await strip.focus();
      await strip.press('Home');
      await expect(strip).toHaveAttribute('aria-valuenow', '0');
      await strip.press('ArrowRight');
      await expect(strip).toHaveAttribute('aria-valuenow', '1');
      await strip.press('End');
      await expect(strip).toHaveAttribute('aria-valuenow', String(cellCount - 1));
      await expect(readout).toHaveText(restingText ?? '');
    });
  }
}

test('latency chart: hovering the scrub overlay draws a crosshair and updates the readout; leaving clears it', async ({
  page,
  startStatus,
}) => {
  await gotoStatus(page, startStatus, 'light');

  const card = page.locator('.card', { hasText: 'Reliability' });
  const chartScrub = card.locator('.chart-scrub');
  const svg = card.locator('.chart svg').first();

  await expect(svg).toBeVisible();
  await expect(chartScrub).toBeVisible();
  await expect(svg.locator('line[stroke-dasharray]')).toHaveCount(0);

  const box = await chartScrub.boundingBox();
  if (!box) throw new Error('status-inspector: chart scrub overlay has no bounding box');
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);

  await expect(svg.locator('line[stroke-dasharray]')).toHaveCount(1);
  // The overlay's own aria-valuenow moved off the resting count-1 default
  // -- hovering the box's horizontal center lands well short of the last
  // cell for a 30-cell range.
  await expect(chartScrub).not.toHaveAttribute('aria-valuenow', String(cellCount - 1));

  await page.mouse.move(box.x, box.y - 50);
  await expect(svg.locator('line[stroke-dasharray]')).toHaveCount(0);
});

test.describe('touch', () => {
  // page.touchscreen requires a touch-capable context -- the project's one
  // "Desktop Chrome" config (playwright.config.ts) has none by default, so
  // this describe block opts in on its own rather than for the whole file.
  test.use({ hasTouch: true });

  test('a tap pins the value past the implicit pointerleave, and a second tap moves it', async ({
    page,
    startStatus,
  }) => {
    await page.setViewportSize({ width: 393, height: 900 });
    await gotoStatus(page, startStatus, 'light');

    const strip = page.locator('.card', { hasText: 'Reliability' }).locator('.strip');
    const box = await strip.boundingBox();
    if (!box) throw new Error('status-inspector: strip has no bounding box');
    const midY = box.y + box.height / 2;

    // A tap (pointerdown with no pointermove after it) pins the value --
    // and it survives the implicit pointerleave a touch pointer fires
    // right after pointerup (see inspect.ts's createScrubHandlers
    // comment); a naive unconditional reset on pointerleave would flash
    // the value and lose it immediately, which is exactly what
    // onPointerDown (not just onPointerMove) and the pointerType==='touch'
    // guard exist to prevent.
    const firstCellX = box.x + box.width * (0.5 / cellCount);
    await page.touchscreen.tap(firstCellX, midY);
    await expect(strip).toHaveAttribute('aria-valuenow', '0');

    // A second tap elsewhere on the strip moves the pinned value.
    const lastCellX = box.x + box.width * ((cellCount - 0.5) / cellCount);
    await page.touchscreen.tap(lastCellX, midY);
    await expect(strip).toHaveAttribute('aria-valuenow', String(cellCount - 1));
  });
});

test('the strip and chart scrub overlay keep touch-action: pan-y, so a vertical touch drag can still scroll the page', async ({
  page,
  startStatus,
}) => {
  await gotoStatus(page, startStatus, 'light');

  // Playwright's touchscreen API has no drag gesture, and real touch-scroll
  // is handled by the browser's compositor rather than page JS either way
  // -- what's actually checkable, and what the drag-still-scrolls contract
  // depends on, is this computed CSS property (see status.css's .strip and
  // .chart-scrub rules): a scrub surface without it would make Chromium
  // treat every touch on it as fully page-scroll-blocking.
  const strip = page.locator('.card', { hasText: 'Reliability' }).locator('.strip');
  const chartScrub = page.locator('.card', { hasText: 'Reliability' }).locator('.chart-scrub');
  await expect(strip).toHaveCSS('touch-action', 'pan-y');
  await expect(chartScrub).toHaveCSS('touch-action', 'pan-y');
});
