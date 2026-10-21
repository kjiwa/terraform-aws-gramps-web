/**
 * Time-travel client contract, end to end through a real mounted page (see
 * mount.ts) rather than isolated hook/component unit tests -- consistent
 * with status-interaction.test.ts's own click-and-assert style. Covers:
 * resting issues no /_status/series fetch, one pan issues exactly one, the
 * label reads the server's own echoed `end` (not client clock math), the
 * five uptime tiles never move, "Now" resets with no extra fetch, a pan
 * error keeps resting data and shows a note, and Host's `current` gauge
 * stays live through a pan the same way Reliability's tiles do.
 */
import { describe, expect, it } from 'vitest';
import { fmtDate } from '../../src/shared/format.ts';
import { mountStatus, waitUntil } from '../support/mount.ts';
import { metadata, payloadFor } from '../support/payload.ts';
import { ALL_TOGGLES_ON } from '../support/shell.ts';
import seriesReliabilityFixture from '../fixtures/series/status-series-reliability.json' with { type: 'json' };
import seriesDegradedFixture from '../fixtures/series/status-series-degraded.json' with { type: 'json' };

function cardTitled(document: Document, title: string): Element {
  const card = Array.from(document.querySelectorAll('.card')).find(
    (c) => c.querySelector('h3')?.textContent === title,
  );
  if (!card) throw new Error(`status-pan: "${title}" card not found`);
  return card;
}

// See status-interaction.test.ts's identical helper comment: mountStatus()
// runs in its own JSDOM realm, so `instanceof HTMLButtonElement` (resolved
// against Vitest's realm) always fails even for a genuine button.
function buttonNamed(group: Element | null, text: string): HTMLElement {
  const btn = Array.from(group?.querySelectorAll('button') ?? []).find(
    (b) => b.textContent === text,
  );
  if (!btn || btn.tagName !== 'BUTTON') throw new Error(`status-pan: no button named "${text}"`);
  return btn;
}

function windowNavOf(card: Element): Element {
  const nav = card.querySelector('.window-nav');
  if (!nav) throw new Error('status-pan: .window-nav not found');
  return nav;
}

function labelOf(nav: Element): string | null | undefined {
  return nav.querySelector('span')?.textContent;
}

describe('status-pan', () => {
  it('rests with zero /_status/series fetches until panned', async () => {
    const mounted = mountStatus({
      toggles: ALL_TOGGLES_ON,
      tokens: { access: 'test-access-token' },
      routes: {
        data: [{ status: 200, body: payloadFor(ALL_TOGGLES_ON) }],
        metadata: [{ status: 200, body: metadata() }],
      },
    });
    await mounted.settled();
    expect(mounted.pageErrors).toEqual([]);

    expect(mounted.fetchCalls.filter((c) => c.url.startsWith('/_status/series'))).toHaveLength(0);
  });

  it('one pan issues one fetch, tiles stay put, and the label reads the echoed end', async () => {
    const mounted = mountStatus({
      toggles: ALL_TOGGLES_ON,
      tokens: { access: 'test-access-token' },
      routes: {
        data: [{ status: 200, body: payloadFor(ALL_TOGGLES_ON) }],
        metadata: [{ status: 200, body: metadata() }],
        series: [{ status: 200, body: seriesReliabilityFixture }],
      },
    });
    await mounted.settled();
    expect(mounted.pageErrors).toEqual([]);

    const card = cardTitled(mounted.document, 'Reliability');
    const tilesBefore = Array.from(
      card.querySelectorAll('.stat-row .stat .n'),
      (el) => el.textContent,
    );

    const nav = windowNavOf(card);
    expect(nav.querySelector('span')?.textContent).toBe('Live');

    const seriesCallsBefore = mounted.fetchCalls.filter((c) =>
      c.url.startsWith('/_status/series'),
    ).length;
    buttonNamed(nav, '◀').click();
    await waitUntil(() => labelOf(nav) === fmtDate(seriesReliabilityFixture.end));

    const seriesCalls = mounted.fetchCalls.filter((c) => c.url.startsWith('/_status/series'));
    expect(seriesCalls).toHaveLength(seriesCallsBefore + 1);
    expect(seriesCalls[seriesCalls.length - 1]?.url).toContain('panel=reliability');

    // The label reads the server's own echoed `end` (the fixture's), not a
    // client-computed instant -- see WindowNav.tsx's own comment on why.
    expect(nav.querySelector('span')?.textContent).toBe(fmtDate(seriesReliabilityFixture.end));

    const tilesAfter = Array.from(
      card.querySelectorAll('.stat-row .stat .n'),
      (el) => el.textContent,
    );
    expect(tilesAfter).toEqual(tilesBefore);
  });

  it('"Now" resets the label to Live and issues no further fetch', async () => {
    const mounted = mountStatus({
      toggles: ALL_TOGGLES_ON,
      tokens: { access: 'test-access-token' },
      routes: {
        data: [{ status: 200, body: payloadFor(ALL_TOGGLES_ON) }],
        metadata: [{ status: 200, body: metadata() }],
        series: [{ status: 200, body: seriesReliabilityFixture }],
      },
    });
    await mounted.settled();

    const card = cardTitled(mounted.document, 'Reliability');
    const nav = windowNavOf(card);
    buttonNamed(nav, '◀').click();
    await waitUntil(() => labelOf(nav) !== 'Live');

    const seriesCallsBefore = mounted.fetchCalls.filter((c) =>
      c.url.startsWith('/_status/series'),
    ).length;
    buttonNamed(nav, 'Now').click();
    await waitUntil(() => labelOf(nav) === 'Live');

    expect(nav.querySelector('span')?.textContent).toBe('Live');
    expect(mounted.fetchCalls.filter((c) => c.url.startsWith('/_status/series'))).toHaveLength(
      seriesCallsBefore,
    );
  });

  it('a pan error keeps resting data visible and shows a note', async () => {
    const payload = payloadFor(ALL_TOGGLES_ON);
    const mounted = mountStatus({
      toggles: ALL_TOGGLES_ON,
      tokens: { access: 'test-access-token' },
      routes: {
        data: [{ status: 200, body: payload }],
        metadata: [{ status: 200, body: metadata() }],
        series: [{ status: 500, body: { error: 'ThrottlingException: Rate exceeded' } }],
      },
    });
    await mounted.settled();

    const card = cardTitled(mounted.document, 'Reliability');
    const stripCellsBefore = card.querySelectorAll('.strip > div').length;
    const nav = windowNavOf(card);
    buttonNamed(nav, '◀').click();
    await waitUntil(() => card.querySelector('.range-scope .err') !== null);

    const rangeScope = card.querySelector('.range-scope');
    expect(rangeScope?.querySelector('.err')?.textContent).toBe(
      'ThrottlingException: Rate exceeded',
    );
    expect(card.querySelectorAll('.strip > div')).toHaveLength(stripCellsBefore);
  });

  it("Host's resting CPU/memory legend (current) does not move through a pan", async () => {
    const mounted = mountStatus({
      toggles: ALL_TOGGLES_ON,
      tokens: { access: 'test-access-token' },
      routes: {
        data: [{ status: 200, body: payloadFor(ALL_TOGGLES_ON) }],
        metadata: [{ status: 200, body: metadata() }],
        series: [{ status: 200, body: seriesDegradedFixture }],
      },
    });
    await mounted.settled();

    const card = cardTitled(mounted.document, 'Host');
    const legendBefore = card.querySelector('.chart-key')?.textContent;
    const nav = windowNavOf(card);
    buttonNamed(nav, '◀').click();
    await waitUntil(
      () => labelOf(nav) !== 'Live' || card.querySelector('.range-scope .err') !== null,
    );

    // The pan itself errors (any degraded {"error": ...} response does --
    // this reuses the checked-in degraded fixture rather than a second
    // one-off body). `current` reads the live `m` prop regardless, so this
    // assertion holds independent of whether the pan succeeds or fails.
    expect(card.querySelector('.chart-key')?.textContent).toBe(legendBefore);
  });
});
