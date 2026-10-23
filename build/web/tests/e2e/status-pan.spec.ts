/**
 * Time-travel controls (WindowNav.tsx / series.ts), against a real browser
 * rather than jsdom.
 */
import type { Page } from '@playwright/test';
import { ALL_TOGGLES_ON } from '../support/shell.ts';
import { expect, test, type StartStatusOptions } from './fixtures.ts';

function reliabilityCard(page: Page) {
  return page.locator('.card', { hasText: 'Reliability' });
}

// Navigates and waits for the first card to actually render -- without
// this, a one-shot read like allTextContents() right after goto() can run
// before the initial GET /_status/data round trip finishes and see an
// empty page instead of a real "before" state (see gotoStatus() in
// status-inspector.spec.ts for the same pattern).
async function gotoStatus(
  page: Page,
  startStatus: (opts: StartStatusOptions) => Promise<string>,
  opts: StartStatusOptions,
): Promise<void> {
  const baseURL = await startStatus(opts);
  await page.goto(`${baseURL}/_status`);
  await expect(page.locator('.card > h3').first()).toBeVisible();
}

test('panning back changes the strip, leaves the five tiles untouched, and shows the echoed window', async ({
  page,
  startStatus,
}) => {
  await gotoStatus(page, startStatus, {
    server: { toggles: ALL_TOGGLES_ON },
    tokens: { access: 'e2e-access-token' },
  });

  const card = reliabilityCard(page);
  const nav = card.locator('.window-nav');
  await expect(nav.locator('span')).toHaveText('Live');

  const tilesBefore = await card.locator('.stat-row .stat .n').allTextContents();
  const stripClassesBefore = await card
    .locator('.strip > div')
    .evaluateAll((els: HTMLElement[]) => els.map((el) => el.className));

  await nav.getByRole('button', { name: 'Earlier window' }).click();

  // seriesFor() forces every reliability cell into the bad band -- a
  // real panned window would differ by coincidence (a different moment in
  // time), this differs by construction, but the assertion is the same
  // either way: the strip actually redrew from the panned response.
  await expect(nav.locator('span')).not.toHaveText('Live');
  const stripClassesAfter = await card
    .locator('.strip > div')
    .evaluateAll((els: HTMLElement[]) => els.map((el) => el.className));
  expect(stripClassesAfter).not.toEqual(stripClassesBefore);
  expect(stripClassesAfter.every((c) => c.includes('c-bad'))).toBe(true);

  const tilesAfter = await card.locator('.stat-row .stat .n').allTextContents();
  expect(tilesAfter).toEqual(tilesBefore);
});

test('"Now" restores the live strip with no further request', async ({ page, startStatus }) => {
  await gotoStatus(page, startStatus, {
    server: { toggles: ALL_TOGGLES_ON },
    tokens: { access: 'e2e-access-token' },
  });

  const card = reliabilityCard(page);
  const nav = card.locator('.window-nav');
  const stripClassesLive = await card
    .locator('.strip > div')
    .evaluateAll((els: HTMLElement[]) => els.map((el) => el.className));

  await nav.getByRole('button', { name: 'Earlier window' }).click();
  await expect(nav.locator('span')).not.toHaveText('Live');

  let seriesRequests = 0;
  page.on('request', (req) => {
    if (req.url().includes('/_status/series')) seriesRequests++;
  });
  await nav.getByRole('button', { name: 'Now' }).click();

  await expect(nav.locator('span')).toHaveText('Live');
  const stripClassesRestored = await card
    .locator('.strip > div')
    .evaluateAll((els: HTMLElement[]) => els.map((el) => el.className));
  expect(stripClassesRestored).toEqual(stripClassesLive);
  expect(seriesRequests).toBe(0);
});

test('the pan controls are keyboard-operable', async ({ page, startStatus }) => {
  await gotoStatus(page, startStatus, {
    server: { toggles: ALL_TOGGLES_ON },
    tokens: { access: 'e2e-access-token' },
  });

  const card = reliabilityCard(page);
  const nav = card.locator('.window-nav');
  const back = nav.getByRole('button', { name: 'Earlier window' });

  await back.focus();
  await page.keyboard.press('Enter');

  await expect(nav.locator('span')).not.toHaveText('Live');
});

test('a pan error keeps the live strip and tiles, and shows a note', async ({
  page,
  startStatus,
}) => {
  await gotoStatus(page, startStatus, {
    server: {
      toggles: ALL_TOGGLES_ON,
      seriesOverride: { status: 500, body: { error: 'ThrottlingException: Rate exceeded' } },
    },
    tokens: { access: 'e2e-access-token' },
  });

  const card = reliabilityCard(page);
  const tilesBefore = await card.locator('.stat-row .stat .n').allTextContents();
  const stripClassesBefore = await card
    .locator('.strip > div')
    .evaluateAll((els: HTMLElement[]) => els.map((el) => el.className));

  await card.locator('.window-nav').getByRole('button', { name: 'Earlier window' }).click();

  await expect(card.locator('.range-scope .err')).toHaveText('ThrottlingException: Rate exceeded');
  const stripClassesAfter = await card
    .locator('.strip > div')
    .evaluateAll((els: HTMLElement[]) => els.map((el) => el.className));
  expect(stripClassesAfter).toEqual(stripClassesBefore);
  expect(await card.locator('.stat-row .stat .n').allTextContents()).toEqual(tilesBefore);
});

test('signed out with public_reliability on: no pan controls render', async ({
  page,
  startStatus,
}) => {
  await gotoStatus(page, startStatus, { server: { toggles: ALL_TOGGLES_ON } });

  await expect(page.locator('.card > h3')).toHaveText(['Reliability', 'Incidents', 'Changes']);
  await expect(
    page.locator('.card', { hasText: 'Reliability' }).locator('.window-nav'),
  ).toHaveCount(0);
});

// Exercises seriesFor()'s host_metrics/assistant arms too, not just
// reliability -- panel=host_metrics feeds Host and Storage independently
// (see Host.tsx's own comment on why), so this confirms panning one
// doesn't affect the other's own pan state or fetch it didn't ask for.
test('Host and Storage pan independently even though both call panel=host_metrics', async ({
  page,
  startStatus,
}) => {
  await gotoStatus(page, startStatus, {
    server: { toggles: ALL_TOGGLES_ON },
    tokens: { access: 'e2e-access-token' },
  });

  const hostNav = page.locator('.card', { hasText: 'Host' }).locator('.window-nav');
  const storageNav = page.locator('.card', { hasText: 'Storage' }).locator('.window-nav');

  await hostNav.getByRole('button', { name: 'Earlier window' }).click();
  await expect(hostNav.locator('span')).not.toHaveText('Live');
  await expect(storageNav.locator('span')).toHaveText('Live');
});
