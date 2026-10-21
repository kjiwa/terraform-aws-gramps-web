/**
 * The built CloudFront error page (dist/pages/errors/generated/502.html),
 * served through page.route on a fake origin so the page's own
 * `/_status/public` fetch can be mocked per state.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { expect, test, type Page, type Route } from '@playwright/test';

const ORIGIN = 'http://error.test';
const HTML = readFileSync(
  resolve(import.meta.dirname, '../../dist/e2e-error/on/pages/errors/generated/502.html'),
  'utf-8',
);

const HTML_OFF = readFileSync(
  resolve(import.meta.dirname, '../../dist/e2e-error/off/pages/errors/generated/502.html'),
  'utf-8',
);

function episodes(durations: number[]): { incidents: unknown[] } {
  return {
    incidents: durations.map((d, i) => ({
      started: new Date(Date.now() - (i + 1) * 86_400_000).toISOString(),
      duration_s: d,
      cause: 'spot-reclaim',
      planned: false,
    })),
  };
}

async function serve(page: Page, publicHandler: (route: Route) => Promise<void>): Promise<void> {
  await page.route(`${ORIGIN}/502.html`, (route) =>
    route.fulfill({ contentType: 'text/html', body: HTML }),
  );
  await page.route('**/_status/public', publicHandler);
}

const json =
  (body: unknown, status = 200, date: string | null = new Date().toUTCString()) =>
  (route: Route) =>
    route.fulfill({
      status,
      contentType: 'application/json',
      headers: date ? { Date: date } : {},
      body: JSON.stringify(body),
    });

async function cardHeight(page: Page): Promise<number> {
  const box = await page.locator('.card').boundingBox();
  return box?.height ?? 0;
}

test('three or more outages show the median', async ({ page }) => {
  await serve(page, json(episodes([60, 300, 900, 400])));
  await page.goto(`${ORIGIN}/502.html`);
  await expect(page.locator('#ctx')).toHaveText(
    'In the last 30 days this site had 4 outages. The median took 6 minutes to clear.',
  );
});

test('one outage shows a count only', async ({ page }) => {
  await serve(page, json(episodes([300])));
  await page.goto(`${ORIGIN}/502.html`);
  await expect(page.locator('#ctx')).toHaveText('1 earlier outage in the last 30 days.');
});

test('no outages says so', async ({ page }) => {
  await serve(page, json({ incidents: [] }));
  await page.goto(`${ORIGIN}/502.html`);
  await expect(page.locator('#ctx')).toHaveText('No outages in the last 30 days.');
});

test('the card height does not change when the line renders', async ({ page }) => {
  let release!: () => void;
  const gate = new Promise<void>((r) => (release = r));
  await serve(page, async (route) => {
    await gate;
    await json(episodes([60, 300, 900]))(route);
  });
  await page.goto(`${ORIGIN}/502.html`);
  await expect(page.locator('#ctx')).toBeEmpty();
  const before = await cardHeight(page);
  release();
  await expect(page.locator('#ctx')).not.toBeEmpty();
  expect(await cardHeight(page)).toBe(before);
});

test('the card height is the same on a narrow viewport', async ({ page }) => {
  await page.setViewportSize({ width: 393, height: 800 });
  let release!: () => void;
  const gate = new Promise<void>((r) => (release = r));
  await serve(page, async (route) => {
    await gate;
    await json(episodes([60, 300, 900]))(route);
  });
  await page.goto(`${ORIGIN}/502.html`);
  const before = await cardHeight(page);
  release();
  await expect(page.locator('#ctx')).not.toBeEmpty();
  expect(await cardHeight(page)).toBe(before);
});

const failures: [string, (route: Route) => Promise<void>][] = [
  ['a 404', (route) => route.fulfill({ status: 404, body: 'nope' })],
  [
    'malformed JSON',
    (route) => route.fulfill({ status: 200, contentType: 'application/json', body: '{oops' }),
  ],
  ['a missing Date header', json(episodes([60, 300, 900]), 200, null)],
  ['a schema mismatch', json({ incidents: { error: 'boom' } })],
  [
    'a response slower than the timeout',
    async (route) => {
      await new Promise((r) => setTimeout(r, 5500));
      await json(episodes([60, 300, 900]))(route).catch(() => {});
    },
  ],
];

for (const [name, handler] of failures) {
  test(`${name} renders nothing and leaves retry and countdown working`, async ({ page }) => {
    await serve(page, handler);
    await page.goto(`${ORIGIN}/502.html`);
    await expect(page.locator('button.retry')).toBeVisible();
    await expect(page.locator('#cd')).not.toHaveText('10');
    await page.waitForTimeout(4500);
    await expect(page.locator('#ctx')).toBeEmpty();
  });
}

test('the countdown ticks and retry exists alongside a rendered line', async ({ page }) => {
  await serve(page, json(episodes([60, 300, 900])));
  await page.goto(`${ORIGIN}/502.html`);
  await expect(page.locator('#ctx')).not.toBeEmpty();
  await expect(page.locator('#cd')).not.toHaveText('10');
  await expect(page.locator('button.retry')).toBeVisible();
  await expect(page.getByRole('link', { name: 'Status page' })).toHaveAttribute('href', '/_status');
});

test.describe('dark scheme', () => {
  test.use({ colorScheme: 'dark' });

  test('applies the dark theme and still renders the line', async ({ page }) => {
    await serve(page, json(episodes([60, 300, 900])));
    await page.goto(`${ORIGIN}/502.html`);
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
    await expect(page.locator('#ctx')).toContainText('3 outages');
  });
});

test('a skewed visitor clock does not change the result when the server sends a Date', async ({
  page,
}) => {
  await page.addInitScript(() => {
    const real = Date.now.bind(Date);
    Date.now = () => real() + 365 * 86_400_000;
  });
  await serve(page, json(episodes([60, 300, 900])));
  await page.goto(`${ORIGIN}/502.html`);
  await expect(page.locator('#ctx')).toContainText('3 outages');
});

test.describe('status page unavailable', () => {
  test('the built page has no context line, status link, or fetch', async ({ page }) => {
    let fetched = false;
    await page.route(`${ORIGIN}/502.html`, (route) =>
      route.fulfill({ contentType: 'text/html', body: HTML_OFF }),
    );
    await page.route('**/_status/public', async (route) => {
      fetched = true;
      await route.abort();
    });
    await page.goto(`${ORIGIN}/502.html`);
    await page.waitForTimeout(500);
    await expect(page.locator('#ctx')).toHaveCount(0);
    await expect(page.getByRole('link', { name: 'Status page' })).toHaveCount(0);
    await expect(page.locator('button.retry')).toBeVisible();
    expect(fetched).toBe(false);
  });
});
