/**
 * Post-render client-side interaction: the range selector and the
 * "Unplanned only" counting-mode toggle both redraw from data already in
 * hand (every range ships in one /_status/data payload; see
 * renderRange()'s comment on why selecting a range never refetches) --
 * this asserts that by pinning the fetch-call count, not just checking the
 * DOM changed.
 */
import { describe, expect, it } from 'vitest';
import { mountStatus } from '../support/mount.ts';
import { metadata, payloadFor } from '../support/payload.ts';
import { ALL_TOGGLES_ON } from '../support/shell.ts';

function fmtPct(n: number, decimals: number): string {
  return n.toFixed(decimals) + '%';
}

function reliabilityCard(document: Document): Element {
  const card = Array.from(document.querySelectorAll('.card')).find(
    (c) => c.querySelector('h3')?.textContent === 'Reliability',
  );
  if (!card) throw new Error('status-interaction: Reliability card not found');
  return card;
}

// Not `btn instanceof HTMLButtonElement`: mountStatus() creates its own
// JSDOM realm, separate from Vitest's own jsdom test environment, and
// `HTMLButtonElement` here resolves to the *latter* -- a cross-realm
// instanceof check against an element from a different window always
// fails, even though the element genuinely is a button (see mount.ts's
// FrozenDate comment for the same realm trap on Date). tagName is
// realm-independent; TS already types querySelectorAll('button')'s result
// as HTMLButtonElement (its tag-name-to-interface overload), so no cast is
// needed to call .click() below.
function buttonNamed(group: Element | null, text: string): HTMLElement {
  const btn = Array.from(group?.querySelectorAll('button') ?? []).find(
    (b) => b.textContent === text,
  );
  if (!btn || btn.tagName !== 'BUTTON')
    throw new Error(`status-interaction: no button named "${text}"`);
  return btn;
}

describe('status-interaction', () => {
  it('switching the detail range redraws the strip from in-hand data, no refetch', async () => {
    const payload = payloadFor(ALL_TOGGLES_ON);
    const mounted = mountStatus({
      toggles: ALL_TOGGLES_ON,
      tokens: { access: 'test-access-token' },
      routes: {
        data: [{ status: 200, body: payload }],
        metadata: [{ status: 200, body: metadata() }],
      },
    });
    await mounted.settled();
    expect(mounted.pageErrors).toEqual([]);

    const card = reliabilityCard(mounted.document);
    const rangeScope = card.querySelector('.range-scope');
    const rangeGroup = rangeScope?.querySelector('[aria-label="Time range"]') ?? null;

    // DEFAULT_RANGE is "30d".
    expect(rangeScope?.querySelectorAll('.strip > div')).toHaveLength(30);
    expect(buttonNamed(rangeGroup, '30d').getAttribute('aria-pressed')).toBe('true');
    expect(buttonNamed(rangeGroup, '90d').getAttribute('aria-pressed')).toBe('false');

    const callsBefore = mounted.fetchCalls.length;
    buttonNamed(rangeGroup, '90d').click();

    expect(rangeScope?.querySelectorAll('.strip > div')).toHaveLength(90);
    expect(buttonNamed(rangeGroup, '90d').getAttribute('aria-pressed')).toBe('true');
    expect(buttonNamed(rangeGroup, '30d').getAttribute('aria-pressed')).toBe('false');
    expect(mounted.fetchCalls).toHaveLength(callsBefore);
  });

  it('"Unplanned only" flips the uptime tiles and the pressed button, with no refetch', async () => {
    const toggles = ALL_TOGGLES_ON;
    const payload = payloadFor(toggles);
    const range24h = 'error' in payload.reliability ? undefined : payload.reliability.ranges['24h'];
    if (!range24h) throw new Error('status-interaction: fixture missing a 24h reliability range');
    const decimals = 'error' in payload.reliability ? 2 : payload.reliability.decimals;

    const mounted = mountStatus({
      toggles,
      tokens: { access: 'test-access-token' },
      routes: {
        data: [{ status: 200, body: payload }],
        metadata: [{ status: 200, body: metadata() }],
      },
    });
    await mounted.settled();
    expect(mounted.pageErrors).toEqual([]);

    const card = reliabilityCard(mounted.document);
    const countingGroup = card.querySelector('[aria-label="Downtime counted"]');
    // Re-queried after the click below, not cached: the tiles re-render
    // fresh nodes on every toggle, so a reference captured beforehand goes
    // stale -- it stops being part of the live tree, and its own
    // textContent (correctly) never changes.
    const firstTileValue = () => card.querySelector('.stat-row .stat .n');

    expect(firstTileValue()?.textContent).toBe(fmtPct(range24h.uptime ?? 0, decimals));
    expect(buttonNamed(countingGroup, 'All outages').getAttribute('aria-pressed')).toBe('true');

    const callsBefore = mounted.fetchCalls.length;
    buttonNamed(countingGroup, 'Unplanned only').click();

    expect(firstTileValue()?.textContent).toBe(fmtPct(range24h.uptime_excl_planned ?? 0, decimals));
    expect(buttonNamed(countingGroup, 'Unplanned only').getAttribute('aria-pressed')).toBe('true');
    expect(buttonNamed(countingGroup, 'All outages').getAttribute('aria-pressed')).toBe('false');
    expect(mounted.fetchCalls).toHaveLength(callsBefore);
  });
});
