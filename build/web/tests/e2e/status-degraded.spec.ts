/**
 * Two ways a real deployment shows up half-broken: one panel's own AWS
 * call failed (safe_section()'s {"error": ...} shape) while its siblings
 * render normally, and a signed-out visitor with public_reliability on
 * seeing public panels with the signin gate sitting below them rather than
 * replacing the page.
 */
import { degradedPayload } from '../support/payload.ts';
import { ALL_TOGGLES_ON } from '../support/shell.ts';
import { expect, test } from './fixtures.ts';

test('a degraded panel shows its own error note without taking its siblings down', async ({
  page,
  startStatus,
}) => {
  const baseURL = await startStatus({
    server: {
      toggles: ALL_TOGGLES_ON,
      dataOverride: {
        status: 200,
        body: degradedPayload(['backups'], 'ThrottlingException: Rate exceeded'),
      },
    },
    tokens: { access: 'e2e-access-token' },
  });
  await page.goto(`${baseURL}/_status`);

  const backupsCard = page.locator('.card', { hasText: 'Backups' });
  await expect(backupsCard.locator('.err')).toHaveText('ThrottlingException: Rate exceeded');
  await expect(backupsCard.locator('.subgrid')).toHaveCount(0);

  // Siblings from every other section render normally.
  await expect(page.locator('.card', { hasText: 'Reliability' }).locator('.stat-row')).toHaveCount(
    1,
  );
  await expect(page.locator('.card', { hasText: 'Host' }).locator('.subgrid')).toHaveCount(1);
  await expect(page.locator('.card', { hasText: 'Storage' }).locator('.subgrid')).toHaveCount(1);
  await expect(page.locator('#gate')).toBeHidden();
});

test('a timed-out panel offers Retry, which refetches and renders the panel', async ({
  page,
  startStatus,
}) => {
  const baseURL = await startStatus({
    server: {
      toggles: ALL_TOGGLES_ON,
      firstDataOverride: { status: 200, body: degradedPayload(['incidents'], 'timed out') },
    },
    tokens: { access: 'e2e-access-token' },
  });
  await page.goto(`${baseURL}/_status`);

  const card = page.locator('.card', { has: page.locator('h3', { hasText: /^Incidents$/ }) });
  await expect(card.locator('.err')).toContainText("Didn't load in time.");
  await card.getByRole('button', { name: 'Retry' }).click();

  await expect(card.locator('.err')).toHaveCount(0);
  await expect(card.locator('.stat-row').first()).toBeVisible();
});

test('a failed Retry keeps the panels on screen', async ({ page, startStatus }) => {
  const baseURL = await startStatus({
    server: {
      toggles: ALL_TOGGLES_ON,
      firstDataOverride: { status: 200, body: degradedPayload(['incidents'], 'timed out') },
      dataOverride: { status: 500, body: { error: 'boom' } },
    },
    tokens: { access: 'e2e-access-token' },
  });
  await page.goto(`${baseURL}/_status`);

  const card = page.locator('.card', { has: page.locator('h3', { hasText: /^Incidents$/ }) });
  await card.getByRole('button', { name: 'Retry' }).click();

  await expect(page.locator('#gate')).toBeHidden();
  await expect(card.locator('.err')).toContainText("Didn't load in time.");
  await expect(
    page.locator('.card', { has: page.locator('h3', { hasText: /^Reliability$/ }) }),
  ).toBeVisible();
});

test('a non-timeout panel error has no Retry', async ({ page, startStatus }) => {
  const baseURL = await startStatus({
    server: {
      toggles: ALL_TOGGLES_ON,
      dataOverride: { status: 200, body: degradedPayload(['backups']) },
    },
    tokens: { access: 'e2e-access-token' },
  });
  await page.goto(`${baseURL}/_status`);

  const card = page.locator('.card', { hasText: 'Backups' });
  await expect(card.locator('.err')).toBeVisible();
  await expect(card.getByRole('button', { name: 'Retry' })).toHaveCount(0);
});

test('signed out with public_reliability on: public panels render with the signin gate below them', async ({
  page,
  startStatus,
}) => {
  const baseURL = await startStatus({ server: { toggles: ALL_TOGGLES_ON } });
  await page.goto(`${baseURL}/_status`);

  await expect(page.locator('.card > h3')).toHaveText(['Reliability', 'Incidents', 'Changes']);
  const gate = page.locator('#gate');
  await expect(gate).toBeVisible();
  await expect(gate.locator('h2')).toHaveText('Please sign in');

  // The gate sits after the panels in document order, not covering them --
  // showGate()'s keepPanels path (see tryPublic()).
  const panelsBox = await page.locator('#panels').boundingBox();
  const gateBox = await gate.boundingBox();
  expect(panelsBox).not.toBeNull();
  expect(gateBox).not.toBeNull();
  if (panelsBox && gateBox)
    expect(gateBox.y).toBeGreaterThanOrEqual(panelsBox.y + panelsBox.height - 1);
});
