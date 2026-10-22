/**
 * The pre-fetch state: what a visitor sees before /_status/data resolves,
 * and what a visitor with JavaScript disabled sees forever. `data-panel`
 * only exists on the static skeleton -- App.tsx's Preact render replaces
 * #panels' contents with markup that carries no such attribute -- so this
 * is the one place in the whole suite where asserting on `[data-panel]` is
 * valid at all.
 */
import { ALL_TOGGLES_ON } from '../support/shell.ts';
import { startStatusServer } from '../support/server.ts';
import { expect, test } from './fixtures.ts';

test('the skeleton stays visible, and a disabled panel is display:none by computed style, while the data fetch is pending', async ({
  page,
  startStatus,
}) => {
  const baseURL = await startStatus({
    server: { toggles: { ...ALL_TOGGLES_ON, backups: false } },
    tokens: { access: 'e2e-access-token' },
  });

  // Holds the request open indefinitely rather than aborting it: an abort
  // rejects fetchStatusData()'s promise, which main() catches into an
  // error gate -- a different state than "still loading," and not the one
  // this test is after. Promise.all([fetchStatusData(), fetchMetadata()])
  // in main() never settles while this route is open, so renderAll()
  // never runs and the static skeleton is what stays on screen.
  await page.route('**/_status/data', () => new Promise(() => {}));

  await page.goto(`${baseURL}/_status`);

  await expect(page.locator('.sk').first()).toBeVisible();
  await expect(page.locator('#gate')).toBeHidden();

  // The panel-flags config (shell.ts's shellHtml()) hides a disabled panel's
  // skeleton by CSS, not by removing it -- computed style is what a config.js-driven
  // data-disabled-panels attribute reproduces.
  const backupsSection = page.locator('[data-panel="backups"]').first();
  await expect(backupsSection).toHaveCSS('display', 'none');
});

test('the skeleton lays out identically to the loaded panels: same card-to-card gap within a section', async ({
  page,
  startStatus,
}) => {
  const baseURL = await startStatus({
    server: { toggles: ALL_TOGGLES_ON },
    tokens: { access: 'e2e-access-token' },
  });

  await page.route('**/_status/data', () => new Promise(() => {}));
  await page.goto(`${baseURL}/_status`);
  await expect(page.locator('.sk').first()).toBeVisible();

  // Service is the skeleton's first section: Reliability then Incidents,
  // adjacent #skeleton > .card siblings with no data-panel gate -- the
  // same two cards #panels renders first once data arrives, so this
  // compares one section's gap against itself rather than two different
  // ones. #skeleton and #panels are required to lay out identically (see
  // status.css's shared #skeleton, #panels rule) precisely so this holds.
  const skeletonCards = page.locator('#skeleton > .card');
  const [skelReliability, skelIncidents] = await Promise.all([
    skeletonCards.nth(0).boundingBox(),
    skeletonCards.nth(1).boundingBox(),
  ]);
  if (!skelReliability || !skelIncidents) {
    throw new Error('status-skeleton: expected two visible skeleton cards');
  }
  const skeletonGap = skelIncidents.y - (skelReliability.y + skelReliability.height);

  await page.unroute('**/_status/data');
  await page.reload();
  await expect(page.locator('.card > h3').first()).toHaveText('Reliability');

  const panelCards = page.locator('#panels > .card');
  const [panelReliability, panelIncidents] = await Promise.all([
    panelCards.nth(0).boundingBox(),
    panelCards.nth(1).boundingBox(),
  ]);
  if (!panelReliability || !panelIncidents) {
    throw new Error('status-skeleton: expected two visible panel cards');
  }
  const panelGap = panelIncidents.y - (panelReliability.y + panelReliability.height);

  // Sub-pixel rounding only -- a real regression here is the whole
  // --gw-space-4 gap collapsing to zero, not a fraction of it.
  expect(Math.abs(skeletonGap - panelGap)).toBeLessThanOrEqual(1);
});

test('with JavaScript disabled, the skeleton still paints and no gate appears', async ({
  browser,
}) => {
  const server = await startStatusServer({ toggles: ALL_TOGGLES_ON });
  try {
    const context = await browser.newContext({ javaScriptEnabled: false });
    const page = await context.newPage();
    await page.goto(`${server.url}/_status`);

    await expect(page.locator('.sk').first()).toBeVisible();
    await expect(page.locator('.card > h3').first()).toHaveText('Reliability');
    await expect(page.locator('#gate')).toBeHidden();

    await context.close();
  } finally {
    await server.close();
  }
});
