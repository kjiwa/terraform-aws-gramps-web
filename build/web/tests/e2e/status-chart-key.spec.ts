/**
 * Chart key spacing: measures the rendered gaps between a .chart-key's direct
 * children and asserts they are equal.
 */
import { ALL_TOGGLES_ON } from '../support/shell.ts';
import { expect, test } from './fixtures.ts';

test('chart-key items are evenly spaced', async ({ page, startStatus }) => {
  const baseURL = await startStatus({
    server: { toggles: ALL_TOGGLES_ON },
    tokens: { access: 'e2e-access-token' },
  });
  await page.goto(`${baseURL}/_status`);

  // Reliability's latency key: two LegendPairs (p50, p90) plus the scope
  // span (`· <date> UTC`) -- three items, two gaps.
  const chartKey = page.locator('.card', { hasText: 'Reliability' }).locator('.chart-key');
  await expect(chartKey.locator('> *')).toHaveCount(3);

  const rects = await chartKey.locator('> *').evaluateAll((els) =>
    els.map((el) => {
      const r = el.getBoundingClientRect();
      return { left: r.left, right: r.right };
    }),
  );

  const gap0 = (rects[1]?.left ?? 0) - (rects[0]?.right ?? 0);
  const gap1 = (rects[2]?.left ?? 0) - (rects[1]?.right ?? 0);
  // Sub-pixel rounding only -- a real regression here is a whole extra
  // margin-right (a few px), not a fraction of one.
  expect(Math.abs(gap0 - gap1)).toBeLessThanOrEqual(1);
});
