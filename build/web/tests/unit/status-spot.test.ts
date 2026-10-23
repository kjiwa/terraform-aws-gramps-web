/**
 * The Spot reclaims panel and the Changes
 * table, mounted in jsdom: presence rules, the client-side range toggle, the
 * operator-only views, and what the public route does and does not show.
 * jsdom has no layout, so the bar chart's SVG is covered by Playwright
 * (tests/e2e/status-spot.spec.ts); everything else renders here.
 */
import { describe, expect, it } from 'vitest';
import type { GETStatusDataResponse } from '../../src/generated/status-payload.d.ts';
import { mountStatus, type Mounted } from '../support/mount.ts';
import {
  metadata,
  payloadFor,
  publicFrom,
  publicPayload,
  quietSpotPayload,
} from '../support/payload.ts';
import { ALL_TOGGLES_ON } from '../support/shell.ts';

const NOW = Date.parse('2026-06-15T12:00:00Z');
const DAY = 86400_000;

async function mountOperator(data: GETStatusDataResponse = payloadFor(ALL_TOGGLES_ON)) {
  const mounted = mountStatus({
    toggles: ALL_TOGGLES_ON,
    tokens: { access: 'test-access-token' },
    routes: {
      data: [{ status: 200, body: data }],
      metadata: [{ status: 200, body: metadata() }],
    },
  });
  await mounted.settled();
  expect(mounted.pageErrors).toEqual([]);
  return mounted;
}

async function mountPublic(data: GETStatusDataResponse = payloadFor(ALL_TOGGLES_ON)) {
  const mounted = mountStatus({
    toggles: ALL_TOGGLES_ON,
    routes: { public: [{ status: 200, body: publicFrom(data) }] },
  });
  await mounted.settled();
  expect(mounted.pageErrors).toEqual([]);
  return mounted;
}

function card(m: Mounted, title: string): Element | undefined {
  return [...m.document.querySelectorAll('.card')].find(
    (c) => c.querySelector('h3')?.textContent === title,
  );
}

function tiles(c: Element | undefined): Record<string, string> {
  return Object.fromEntries(
    [...(c?.querySelectorAll('.stat') ?? [])].map((s) => [
      s.querySelector('.l')?.textContent ?? '',
      s.querySelector('.n')?.textContent ?? '',
    ]),
  );
}

function press(c: Element | undefined, text: string): void {
  const btn = [...(c?.querySelectorAll('.toggle-group button') ?? [])].find(
    (b) => b.textContent === text,
  );
  if (!btn) throw new Error(`no button "${text}"`);
  (btn as HTMLElement).click();
}

function headings(c: Element | undefined): (string | null)[] {
  return [...(c?.querySelectorAll('h4') ?? [])].map((h) => h.textContent);
}

describe('Spot panel presence', () => {
  it('follows Incidents in the Service section, on both routes', async () => {
    const titles = (m: Mounted) =>
      [...m.document.querySelectorAll('.card > h3')].map((h) => h.textContent);
    expect(titles(await mountOperator()).slice(0, 3)).toEqual([
      'Reliability',
      'Incidents (1y)',
      'Spot reclaims',
    ]);
    expect(titles(await mountPublic())).toEqual(['Reliability', 'Incidents (1y)', 'Spot reclaims']);
  });

  it('is absent for On-Demand with no reclaims', async () => {
    const m = await mountOperator(quietSpotPayload(false));
    expect(card(m, 'Spot reclaims')).toBeUndefined();
    expect(card(await mountPublic(quietSpotPayload(false)), 'Spot reclaims')).toBeUndefined();
  });

  it('is present at zero for a Spot deployment with no reclaims', async () => {
    const m = await mountOperator(quietSpotPayload(true));
    const spot = card(m, 'Spot reclaims');
    expect(spot).toBeDefined();
    expect(tiles(spot)['Reclaims']).toBe('0');
    expect(tiles(spot)['Caused an outage']).toBe('0');
    expect(spot?.textContent).toContain('No reclaims in the last 30 days.');
    expect(spot?.querySelector('.bar-chart')).toBeNull();
    press(spot, '1y');
    expect(spot?.textContent).toContain('No reclaims in the last year.');
  });

  it('shows for an On-Demand deployment whose year still holds a reclaim', async () => {
    const data = payloadFor(ALL_TOGGLES_ON);
    data.spot_enabled = false;
    expect(card(await mountOperator(data), 'Spot reclaims')).toBeDefined();
  });
});

describe('Spot panel contents', () => {
  it('counts warnings in range independently of the payload helpers, and the toggle re-slices client-side', async () => {
    const data = payloadFor(ALL_TOGGLES_ON);
    const warningsWithin = (days: number) =>
      (Array.isArray(data.interruptions) ? data.interruptions : []).filter(
        (w) => Date.parse(w.time) >= NOW - days * DAY && Date.parse(w.time) <= NOW,
      ).length;
    const m = await mountOperator(data);
    const spot = card(m, 'Spot reclaims');
    expect(tiles(spot)['Reclaims']).toBe(String(warningsWithin(30)));

    const callsBefore = m.fetchCalls.length;
    press(spot, '90d');
    expect(tiles(spot)['Reclaims']).toBe(String(warningsWithin(90)));
    press(spot, '1y');
    expect(tiles(spot)['Reclaims']).toBe(String(warningsWithin(365)));
    expect(m.fetchCalls.length).toBe(callsBefore);
  });

  it('lists the same weekly numbers in the data table as the tiles total', async () => {
    const spot = card(await mountOperator(), 'Spot reclaims');
    const rows = [...(spot?.querySelectorAll('details tbody tr') ?? [])].map((tr) =>
      [...tr.querySelectorAll('td')].map((td) => Number(td.textContent) || 0),
    );
    const outages = rows.reduce((a, r) => a + (r[1] ?? 0), 0);
    const absorbed = rows.reduce((a, r) => a + (r[2] ?? 0), 0);
    expect(String(outages)).toBe(tiles(spot)['Caused an outage']);
    expect(String(absorbed)).toBe(tiles(spot)['Absorbed']);
    expect(spot?.textContent).toContain('Absorbed is approximate');
  });

  it('shows recovery split and pools to an operator only', async () => {
    const operator = card(await mountOperator(), 'Spot reclaims');
    expect(headings(operator)).toEqual(['Reclaims per week', 'Recovery split', 'Pools']);
    expect(operator?.querySelector('.split-bar')).not.toBeNull();
    const poolRows = operator?.querySelectorAll('h4 ~ .table-scroll tbody tr') ?? [];
    expect(poolRows.length).toBeLessThanOrEqual(7);

    const publicCard = card(await mountPublic(), 'Spot reclaims');
    expect(headings(publicCard)).toEqual(['Reclaims per week']);
    expect(publicCard?.querySelector('.split-bar')).toBeNull();
    expect(Object.keys(tiles(publicCard))).toEqual([
      'Reclaims',
      'Caused an outage',
      'Absorbed',
      'Downtime',
      'Share of downtime',
      'Median recovery',
    ]);
  });

  it('replaces the split with a count note below three timed outages, never inventing numbers', async () => {
    const data = payloadFor(ALL_TOGGLES_ON);
    if (Array.isArray(data.incidents)) {
      data.incidents.forEach((ep) => {
        delete ep.capacity_wait_s;
        delete ep.boot_to_serve_s;
      });
    }
    const spot = card(await mountOperator(data), 'Spot reclaims');
    expect(spot?.querySelector('.split-bar')).toBeNull();
    expect(spot?.textContent).toMatch(
      /Recovery timing is recorded for 0 of \d+ reclaim outages so far/,
    );
  });
});

describe('events lane removal', () => {
  it('renders no events lane or events legend', async () => {
    const m = await mountOperator();
    const rel = card(m, 'Reliability');
    expect(rel?.querySelector('.lane')).toBeNull();
    expect(rel?.querySelector('.legend-groups')?.textContent).not.toContain('Events');
  });
});

describe('Changes table', () => {
  function changeRows(c: Element | undefined): string[][] {
    const details = [...(c?.querySelectorAll('details') ?? [])].find((d) =>
      d.querySelector('summary')?.textContent?.includes('change'),
    );
    return [...(details?.querySelectorAll('tbody tr') ?? [])].map((tr) =>
      [...tr.querySelectorAll('td')].map((td) => td.textContent ?? ''),
    );
  }

  it('lists everything the payload carries for an operator, newest first', async () => {
    const incidents = card(await mountOperator(), 'Incidents (1y)');
    const headers = [
      ...(incidents?.querySelectorAll('details')[1]?.querySelectorAll('th') ?? []),
    ].map((th) => th.textContent);
    expect(headers).toEqual([
      'Time (UTC)',
      'What',
      'Trigger',
      'Outcome',
      'Duration',
      'Outage',
      'Id',
      'Description',
    ]);
    const rows = changeRows(incidents);
    expect(rows).toHaveLength(7);
    const times = rows.map((r) => r[0] ?? '');
    expect(times).toEqual([...times].sort().reverse());
    expect(rows.map((r) => r[2])).toContain('autoscaling');
    expect(rows.map((r) => r[1])).toContain('instance refresh');
    expect(incidents?.querySelectorAll('.badge-bad').length).toBeGreaterThan(0);
  });

  it('lists deliberate changes only, and only the carried columns, on the public route', async () => {
    const incidents = card(await mountPublic(), 'Incidents (1y)');
    const rows = changeRows(incidents);
    const expected = publicPayload().changes;
    expect(rows).toHaveLength(Array.isArray(expected) ? expected.length : -1);
    expect(rows.map((r) => r[2])).not.toContain('autoscaling');
    const headers = [
      ...(incidents?.querySelectorAll('details')[1]?.querySelectorAll('th') ?? []),
    ].map((th) => th.textContent);
    expect(headers).toEqual(['Time (UTC)', 'What', 'Trigger', 'Outcome']);
  });
});
