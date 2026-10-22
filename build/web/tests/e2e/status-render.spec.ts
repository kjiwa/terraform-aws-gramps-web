/**
 * Real layout, real Chromium -- the geometry jsdom's mountStatus() cannot
 * give (drawChart() early-returns at zero clientWidth). 8 combinations:
 * all-off, all-on, and each toggle flipped off alone. Card set (shared with
 * status-matrix.test.ts via tests/support/expected.ts), SVG count and
 * non-degenerate viewBoxes, the default range's strip cell count, and
 * legend contents.
 */
import { expectedCards, expectedSections } from '../support/expected.ts';
import { ALL_TOGGLES_OFF, ALL_TOGGLES_ON, type Toggles } from '../support/shell.ts';
import { expect, test } from './fixtures.ts';

const TOGGLE_KEYS = [
  'host_metrics',
  'cost',
  'backups',
  'assistant',
  'public_reliability',
] as const satisfies readonly (keyof Toggles)[];

const COMBOS: { name: string; toggles: Toggles }[] = [
  { name: 'all-off', toggles: ALL_TOGGLES_OFF },
  { name: 'all-on', toggles: ALL_TOGGLES_ON },
  ...TOGGLE_KEYS.map((key) => ({
    name: `${key}-off`,
    toggles: { ...ALL_TOGGLES_ON, [key]: false },
  })),
];

// One SVG per chart that actually has data to draw: the Reliability latency
// chart and the Spot weekly bar chart always (the fixture holds reclaims), plus Host's
// CPU/memory chart and Storage's disk-used chart when host_metrics is on
// (the checked-in fixture's host_metrics carries the byte path, so Storage
// always has a chart to draw whenever the panel is on at all -- see
// tests/support/payload.ts's percentDiskPayload() for the other path,
// covered separately in status-storage-chart.spec.ts), and Assistant's
// tokens chart when assistant is on.
function expectedSvgCount(t: Toggles): number {
  return 2 + (t.host_metrics ? 2 : 0) + (t.assistant ? 1 : 0);
}

for (const { name, toggles } of COMBOS) {
  test(`renders the expected cards and charts: ${name}`, async ({ page, startStatus }) => {
    const baseURL = await startStatus({
      server: { toggles },
      tokens: { access: 'e2e-access-token' },
    });
    await page.goto(`${baseURL}/_status`);

    await expect(page.locator('.card')).toHaveCount(expectedCards(toggles).length);
    await expect(page.locator('.card > h3')).toHaveText(expectedCards(toggles));
    await expect(page.locator('.section-head')).toHaveText(expectedSections(toggles));
    await expect(page.locator('.sk')).toHaveCount(0);

    const svgs = page.locator('#panels svg');
    await expect(svgs).toHaveCount(expectedSvgCount(toggles));
    const viewBoxes = await svgs.evaluateAll((nodes) =>
      nodes.map((n) => n.getAttribute('viewBox')),
    );
    for (const viewBox of viewBoxes) {
      const parts = (viewBox ?? '').split(' ').map(Number);
      expect(parts).toHaveLength(4);
      expect(parts[2]).toBeGreaterThan(0);
      expect(parts[3]).toBeGreaterThan(0);
    }

    // DEFAULT_RANGE is "30d"; RANGES' own cell count for it (status.py:165)
    // is 30, independent of every toggle above.
    await expect(
      page.locator('.card', { hasText: 'Reliability' }).locator('.strip > div'),
    ).toHaveCount(30);

    const legend = page.locator('.card', { hasText: 'Reliability' }).locator('.legend-groups');
    await expect(legend).toContainText('≥99.9%');
    await expect(legend).toContainText('no data');
    await expect(legend).toContainText('in progress');

    const latencyKey = page
      .locator('.card', { hasText: 'Reliability' })
      .locator('.chart-key')
      .first();
    await expect(latencyKey).toContainText('p50');
    await expect(latencyKey).toContainText('p90');
  });
}
