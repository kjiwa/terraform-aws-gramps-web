/**
 * The Incidents card (with its Spot subsection) and the Changes
 * card, mounted in jsdom: presence rules, the client-side range and pan, the
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

describe('Spot subsection presence', () => {
  it('has no card of its own: Incidents follows Reliability, on both routes', async () => {
    const titles = (m: Mounted) =>
      [...m.document.querySelectorAll('.card > h3')].map((h) => h.textContent);
    expect(titles(await mountOperator()).slice(0, 2)).toEqual(['Reliability', 'Incidents']);
    expect(titles(await mountPublic())).toEqual(['Reliability', 'Incidents', 'Changes']);
  });

  it('is absent for On-Demand with no reclaims', async () => {
    const op = card(await mountOperator(quietSpotPayload(false)), 'Incidents');
    expect(headings(op)).not.toContain('Spot reclaims');
    const pub = card(await mountPublic(quietSpotPayload(false)), 'Incidents');
    expect(headings(pub)).not.toContain('Spot reclaims');
  });

  it('is present at zero for a Spot deployment with no reclaims', async () => {
    const incidents = card(await mountOperator(quietSpotPayload(true)), 'Incidents');
    expect(headings(incidents)).toContain('Spot reclaims');
    expect(tiles(incidents)['Reclaim warnings']).toBe('0');
    expect(tiles(incidents)['Caused an outage']).toBe('0');
    expect(incidents?.querySelector('.split-bar')).toBeNull();
  });

  it('shows for an On-Demand deployment whose year still holds a reclaim', async () => {
    const data = payloadFor(ALL_TOGGLES_ON);
    data.spot_enabled = false;
    const incidents = card(await mountOperator(data), 'Incidents');
    expect(headings(incidents)).toContain('Spot reclaims');
  });
});

describe('Incidents range model', () => {
  it('counts warnings and episodes per window independently of the helpers, re-slicing client-side', async () => {
    const data = payloadFor(ALL_TOGGLES_ON);
    const warnings = Array.isArray(data.interruptions) ? data.interruptions : [];
    const episodes = Array.isArray(data.incidents) ? data.incidents : [];
    const within = (days: number, iso: string) =>
      Date.parse(iso) >= NOW - days * DAY && Date.parse(iso) <= NOW;
    const m = await mountOperator(data);
    const incidents = card(m, 'Incidents');
    const callsBefore = m.fetchCalls.length;
    const spans: [string, number][] = [
      ['30d', 30],
      ['90d', 90],
      ['1y', 364],
    ];
    for (const [label, days] of spans) {
      press(incidents, label);
      expect(tiles(incidents)['Reclaim warnings']).toBe(
        String(warnings.filter((w) => within(days, w.time)).length),
      );
      expect(tiles(incidents)['incidents']).toBe(
        String(episodes.filter((ep) => within(days, ep.started)).length),
      );
    }
    expect(m.fetchCalls.length).toBe(callsBefore);
  });

  it('offers all five ranges, defaulting to 30d', async () => {
    const incidents = card(await mountOperator(), 'Incidents');
    const buttons = [...(incidents?.querySelectorAll('.toggle-group button') ?? [])];
    expect(buttons.map((b) => b.textContent)).toEqual(['24h', '7d', '30d', '90d', '1y']);
    expect(buttons.filter((b) => b.getAttribute('aria-pressed') === 'true')).toHaveLength(1);
    expect(buttons.find((b) => b.getAttribute('aria-pressed') === 'true')?.textContent).toBe('30d');
  });

  it('makes the table follow the window', async () => {
    const incidents = card(await mountOperator(), 'Incidents');
    const summaryCount = () =>
      Number(/^(\d+) incident/.exec(incidents?.querySelector('summary')?.textContent ?? '')?.[1]);
    expect(summaryCount()).toBe(Number(tiles(incidents)['incidents']));
    press(incidents, '1y');
    expect(summaryCount()).toBe(Number(tiles(incidents)['incidents']));
  });

  it('pans client-side and returns to live', async () => {
    const m = await mountOperator();
    const incidents = card(m, 'Incidents');
    const label = () => incidents?.querySelector('.window-nav span')?.textContent;
    const callsBefore = m.fetchCalls.length;
    expect(label()).toBe('Live');
    (incidents?.querySelector('[aria-label="Earlier window"]') as HTMLElement).click();
    expect(label()).not.toBe('Live');
    expect(label()).toMatch(/UTC/);
    [...(incidents?.querySelectorAll('.window-nav button') ?? [])]
      .find((b) => b.textContent === 'Now')
      ?.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    expect(label()).toBe('Live');
    expect(m.fetchCalls.length).toBe(callsBefore);
  });
});

describe('Spot subsection contents', () => {
  it('shows recovery split and pools to an operator only, pools collapsed', async () => {
    const operator = card(await mountOperator(), 'Incidents');
    expect(headings(operator)).toEqual(['Spot reclaims', 'Recovery split']);
    expect(operator?.querySelector('.split-bar')).not.toBeNull();
    const pools = [...(operator?.querySelectorAll('details') ?? [])].find(
      (d) => d.querySelector('summary')?.textContent === 'Pools',
    );
    expect(pools).toBeDefined();
    expect(pools?.hasAttribute('open')).toBe(false);
    expect(pools?.querySelectorAll('tbody tr').length).toBeLessThanOrEqual(7);

    const publicCard = card(await mountPublic(), 'Incidents');
    expect(headings(publicCard)).toEqual(['Spot reclaims']);
    expect(publicCard?.querySelector('.split-bar')).toBeNull();
    expect(Object.keys(tiles(publicCard))).toEqual([
      'incidents',
      'total downtime',
      'unplanned',
      'median recovery',
      'Reclaim warnings',
      'Caused an outage',
      'Share of downtime',
    ]);
  });

  it('draws no split, and no placeholder, below three timed outages', async () => {
    const data = payloadFor(ALL_TOGGLES_ON);
    if (Array.isArray(data.incidents)) {
      data.incidents.forEach((ep) => {
        delete ep.capacity_wait_s;
        delete ep.boot_to_serve_s;
      });
    }
    const incidents = card(await mountOperator(data), 'Incidents');
    expect(incidents?.querySelector('.split-bar')).toBeNull();
    expect(headings(incidents)).toEqual(['Spot reclaims']);
    expect(incidents?.textContent).not.toContain('Recovery timing is recorded');
    expect(incidents?.textContent).not.toContain('Absorbed');
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

describe('Changes card', () => {
  const changesCard = (m: Mounted) => card(m, 'Changes');
  const headers = (c: Element | undefined) =>
    [...(c?.querySelectorAll('thead th') ?? [])].map((th) => th.textContent);
  const rows = (c: Element | undefined) =>
    [...(c?.querySelectorAll('tbody tr') ?? [])].map((tr) =>
      [...tr.querySelectorAll('td')].map((td) => td.textContent ?? ''),
    );
  const summary = (c: Element | undefined) => c?.querySelector('summary')?.textContent ?? '';

  it('defaults to deliberate changes, without the trigger column, newest first', async () => {
    const c = changesCard(await mountOperator());
    expect(c?.querySelector('[aria-pressed="true"]')?.textContent).toBe('Deliberate');
    expect(headers(c)).toEqual(['Time (UTC)', 'Change', 'Outcome', 'Duration', 'Outage', 'Id']);
    const r = rows(c);
    expect(r).toHaveLength(5);
    const times = r.map((x) => x[0] ?? '');
    expect(times).toEqual([...times].sort().reverse());
    expect(r.map((x) => x[1])).toContain('instance refresh');
    expect(summary(c)).toMatch(/^5 changes · most recent /);
    expect(c?.querySelectorAll('.badge-bad').length).toBeGreaterThan(0);
  });

  it('shows every change and the trigger under All, the summary counting what is shown', async () => {
    const c = changesCard(await mountOperator());
    press(c, 'All');
    expect(headers(c)).toEqual([
      'Time (UTC)',
      'Change',
      'Trigger',
      'Outcome',
      'Duration',
      'Outage',
      'Id',
    ]);
    expect(rows(c)).toHaveLength(7);
    expect(rows(c).map((x) => x[2])).toContain('autoscaling');
    expect(summary(c)).toMatch(/^7 changes · most recent /);
    press(c, 'Deliberate');
    expect(rows(c)).toHaveLength(5);
  });

  it('moves the description into the row title and out of the columns', async () => {
    const c = changesCard(await mountOperator());
    expect(headers(c)).not.toContain('Description');
    const titled = [...(c?.querySelectorAll('tbody tr') ?? [])].filter((tr) =>
      tr.getAttribute('title')?.includes('Rolled back to the previous revision'),
    );
    expect(titled).toHaveLength(1);
  });

  it('on the public route lists the carried columns with no filter to flip', async () => {
    const c = changesCard(await mountPublic());
    expect(headers(c)).toEqual(['Time (UTC)', 'Change', 'Outcome']);
    expect(c?.querySelector('.toggle-group')).toBeNull();
    const expected = publicPayload().changes;
    expect(rows(c)).toHaveLength(Array.isArray(expected) ? expected.length : -1);
  });
});
