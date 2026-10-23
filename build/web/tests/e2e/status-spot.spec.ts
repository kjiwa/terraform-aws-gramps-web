/**
 * The Spot reclaims panel in real Chromium: presence rules, the client-side
 * range toggle, the bar chart's tooltip on hover and focus, and the
 * operator-only and public views. Layout-dependent, so it lives here rather
 * than in Vitest (tests/unit/status-spot.test.ts covers the rest).
 */
import type { Page } from '@playwright/test';
import { payloadFor, publicFrom, quietSpotPayload } from '../support/payload.ts';
import { ALL_TOGGLES_ON } from '../support/shell.ts';
import { expect, test, type StartStatusOptions } from './fixtures.ts';

type Start = (opts: StartStatusOptions) => Promise<string>;

const spotCard = (page: Page) =>
  page.locator('.card', { has: page.locator('h3', { hasText: 'Spot reclaims' }) });
const reclaimsTile = (page: Page) =>
  spotCard(page).locator('.stat', { hasText: 'Reclaims' }).first().locator('.n');

async function openOperator(page: Page, start: Start, body = payloadFor(ALL_TOGGLES_ON)) {
  const baseURL = await start({
    server: { toggles: ALL_TOGGLES_ON, dataOverride: { status: 200, body } },
    tokens: { access: 'e2e-access-token' },
  });
  await page.goto(`${baseURL}/_status`);
  await expect(page.locator('.card > h3').first()).toBeVisible();
}

test('shows tiles, the weekly chart, and the operator views with data', async ({
  page,
  startStatus,
}) => {
  await openOperator(page, startStatus);
  const card = spotCard(page);
  await expect(card).toBeVisible();
  await expect(card.locator('.stat')).toHaveCount(6);
  await expect(card.locator('.bar-chart svg')).toHaveCount(1);
  await expect(card.locator('.bar-hit').first()).toHaveAttribute(
    'aria-label',
    /Week of .*Caused an outage \d+, Absorbed \d+, total \d+/,
  );
  await expect(card.getByRole('heading', { name: 'Recovery split' })).toBeVisible();
  await expect(card.getByRole('heading', { name: 'Pools' })).toBeVisible();
});

test('the range toggle changes the tiles without a refetch', async ({ page, startStatus }) => {
  await openOperator(page, startStatus);
  const before = await reclaimsTile(page).textContent();
  let fetches = 0;
  page.on('request', (r) => {
    if (r.url().includes('/_status/')) fetches++;
  });
  await spotCard(page).getByRole('button', { name: '1y' }).click();
  await expect(reclaimsTile(page)).not.toHaveText(before ?? '');
  expect(fetches).toBe(0);
});

test('a bar shows its tooltip on hover and on keyboard focus', async ({ page, startStatus }) => {
  await openOperator(page, startStatus);
  const bars = spotCard(page).locator('.bar-hit');
  await bars.nth(1).hover();
  const tip = spotCard(page).locator('.tip');
  await expect(tip).toContainText('Week of');
  await expect(tip).toContainText('Caused an outage');
  await expect(tip).toContainText('Absorbed');
  await expect(tip).toContainText('total');
  await page.mouse.move(0, 0);
  await expect(tip).toHaveCount(0);

  await bars.last().focus();
  await expect(tip).toBeVisible();
  await page.keyboard.press('ArrowLeft');
  await expect(bars.nth((await bars.count()) - 2)).toBeFocused();
  await expect(tip).toBeVisible();
});

test('the panel is absent for On-Demand with no reclaims', async ({ page, startStatus }) => {
  await openOperator(page, startStatus, quietSpotPayload(false));
  await expect(spotCard(page)).toHaveCount(0);
});

test('the panel shows at zero for Spot with no reclaims', async ({ page, startStatus }) => {
  await openOperator(page, startStatus, quietSpotPayload(true));
  await expect(spotCard(page)).toContainText('No reclaims in the last 30 days.');
  await expect(reclaimsTile(page)).toHaveText('0');
});

test('the public view shows tiles and the chart, not the pool table or the recovery split', async ({
  page,
  startStatus,
}) => {
  const baseURL = await startStatus({
    server: {
      toggles: ALL_TOGGLES_ON,
      publicOverride: { status: 200, body: publicFrom(payloadFor(ALL_TOGGLES_ON)) },
    },
  });
  await page.goto(`${baseURL}/_status`);
  const card = spotCard(page);
  await expect(card.locator('.stat')).toHaveCount(6);
  await expect(card.locator('.bar-chart svg')).toHaveCount(1);
  await expect(card.getByRole('heading', { name: 'Pools' })).toHaveCount(0);
  await expect(card.getByRole('heading', { name: 'Recovery split' })).toHaveCount(0);
});

test('the public Changes table lists deliberate changes only', async ({ page, startStatus }) => {
  const baseURL = await startStatus({
    server: {
      toggles: ALL_TOGGLES_ON,
      publicOverride: { status: 200, body: publicFrom(payloadFor(ALL_TOGGLES_ON)) },
    },
  });
  await page.goto(`${baseURL}/_status`);
  await page.locator('summary', { hasText: /\d+ changes?/ }).click();
  const triggers = page
    .locator('details', { hasText: 'Trigger' })
    .locator('tbody tr td:nth-child(3)');
  await expect(triggers.filter({ hasText: 'autoscaling' })).toHaveCount(0);
  await expect(triggers.filter({ hasText: 'rollback' })).toHaveCount(1);
});

test('the strip readout names the incidents of the hovered cell, with no layout jump', async ({
  page,
  startStatus,
}) => {
  await openOperator(page, startStatus);
  const card = page.locator('.card', { has: page.locator('h3', { hasText: 'Reliability' }) });
  await expect(card.locator('.lane')).toHaveCount(0);
  const strip = card.locator('.strip');
  const readout = card.locator('.strip-key');
  const box = await strip.boundingBox();
  const before = await card.boundingBox();
  if (!box) throw new Error('strip has no box');

  const cells = await strip.locator('> div').count();
  let named = false;
  for (let i = 0; i < cells && !named; i++) {
    await page.mouse.move(box.x + ((i + 0.5) / cells) * box.width, box.y + box.height / 2);
    named = /\d+ incidents?: /.test((await readout.textContent()) ?? '');
  }
  expect(named).toBe(true);
  expect(await card.locator('.tip').count()).toBe(0);
  expect((await card.boundingBox())?.height).toBe(before?.height);
});
