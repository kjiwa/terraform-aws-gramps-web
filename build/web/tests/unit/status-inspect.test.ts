/**
 * Scrub primitives (src/status/inspect.ts) plus ranges.ts's relativeLabel().
 * indexFromPointer/relativeLabel are pure, tested directly. Keyboard stepping
 * and resetKey are exercised through a real mounted page (the reliability
 * strip, whose onKeyDown works fine here -- `onkeydown` is a real jsdom Element
 * property, so Preact's own casing inference resolves it to the correct
 * "keydown" DOM event name).
 *
 * No pointer/touch coverage lives in this file, by measurement, not
 * assumption: a throwaway probe first confirmed jsdom 25 has no
 * `PointerEvent` global, which looked survivable (Preact attaches handlers
 * via a plain addEventListener call it can reach with any dispatched
 * event). But building the actual test against a real mounted page (not
 * the probe's bare addEventListener) surfaced a second, more specific gap:
 * Preact's setProperty (preact/src/diff/props.js) only lowercases an event
 * prop's name when `"on" + name.toLowerCase() in dom` is true -- true in a
 * real browser (`onpointermove` is a real GlobalEventHandlers IDL
 * property), but false in jsdom, which doesn't implement the Pointer
 * Events spec at all. Preact then falls back to the *unlowercased* prop
 * suffix, registering a listener for the literal string "PointerMove"
 * (mixed case) -- which a dispatched "pointermove" (lowercase, the only
 * spelling any real event uses) never matches. Confirmed directly: adding
 * a console.log inside the handler and dispatching a MouseEvent named
 * "pointermove" at a mounted page never printed it. This is a property of
 * jsdom + Preact together, not a bug in inspect.ts -- pointer/touch
 * coverage (the pointerType==='touch' guard, the drag-still-scrolls
 * contract, real crosshair geometry) lives entirely in Playwright
 * (status-inspector.spec.ts), where a real Chromium DOM does define
 * `onpointermove`.
 */
import { describe, expect, it } from 'vitest';
import { indexFromPointer } from '../../src/status/inspect.ts';
import { relativeLabel } from '../../src/status/ranges.ts';
import { mountStatus } from '../support/mount.ts';
import { metadata, payloadFor } from '../support/payload.ts';
import { ALL_TOGGLES_ON } from '../support/shell.ts';

function rect(left: number, width: number): DOMRect {
  return {
    left,
    width,
    right: left + width,
    top: 0,
    bottom: 0,
    height: 0,
    x: left,
    y: 0,
  } as DOMRect;
}

describe('indexFromPointer', () => {
  const count = 10;
  const r = rect(100, 200); // 20px per cell

  it('picks the cell whose center the pointer sits over', () => {
    for (let i = 0; i < count; i++) {
      const centerX = r.left + ((i + 0.5) / count) * r.width;
      expect(indexFromPointer(centerX, r, count)).toBe(i);
    }
  });

  it('rounds to the nearest cell at a boundary', () => {
    // The boundary between cell 3 and cell 4 sits at x = left + 4/10 * width.
    const boundary = r.left + (4 / count) * r.width;
    // Exactly on the boundary: (x/width)*count - 0.5 = 3.5, which
    // Math.round ties to 4 (round-half-up).
    expect(indexFromPointer(boundary, r, count)).toBe(4);
    expect(indexFromPointer(boundary - 1, r, count)).toBe(3);
  });

  it('clamps to 0 for a pointer left of the surface', () => {
    expect(indexFromPointer(r.left - 500, r, count)).toBe(0);
  });

  it('clamps to count - 1 for a pointer right of the surface', () => {
    expect(indexFromPointer(r.left + r.width + 500, r, count)).toBe(count - 1);
  });

  it('returns 0 for a zero-width rect or zero count, never NaN or a throw', () => {
    expect(indexFromPointer(150, rect(100, 0), count)).toBe(0);
    expect(indexFromPointer(150, r, 0)).toBe(0);
  });
});

describe('relativeLabel', () => {
  it('reads "now" for an empty range', () => {
    expect(relativeLabel('24h', 0, 0)).toBe('now');
  });

  it('the most recent cell of a 24h range (48 cells, 1800s each) is ~15 minutes ago', () => {
    // cell 47 (the last of 48): ago = (48 - 1 - 47 + 0.5) * 1800s = 900s = 15m.
    expect(relativeLabel('24h', 47, 48)).toBe('≈15m ago');
  });

  it('the oldest cell of a 24h range is ~24 hours ago', () => {
    // cell 0: ago = (48 - 1 - 0 + 0.5) * 1800s = 47.5 * 1800s ≈ 23.75h.
    expect(relativeLabel('24h', 0, 48)).toBe('≈24h ago');
  });

  it('a 30d range (30 daily cells) reports whole days', () => {
    // cell 29 (last): ago = 0.5 * 86400s = 12h -> rounds to 0d, "now" branch
    // isn't hit (12h >= 60s and >= 60min), so it should read in hours.
    expect(relativeLabel('30d', 29, 30)).toBe('≈12h ago');
    // cell 0 (oldest): ago = 29.5 * 86400s ≈ 29.5d.
    expect(relativeLabel('30d', 0, 30)).toBe('≈30d ago');
  });
});

function reliabilityCard(document: Document): Element {
  const card = Array.from(document.querySelectorAll('.card')).find(
    (c) => c.querySelector('h3')?.textContent === 'Reliability',
  );
  if (!card) throw new Error('status-inspect: Reliability card not found');
  return card;
}

// Same realm caution as status-interaction.test.ts's buttonNamed(): mounted
// pages live in their own JSDOM instance, so cross-realm instanceof always
// fails even for a genuine element -- tagName/className checks are
// realm-independent.
function strip(card: Element): HTMLElement {
  const el = card.querySelector('.strip');
  if (!el || el.tagName !== 'DIV') throw new Error('status-inspect: strip not found');
  return el as HTMLElement;
}

function stripKeyText(card: Element): string | null | undefined {
  return card.querySelector('.strip-key')?.textContent;
}

// The lib.dom Window interface (what Mounted.window is typed as) doesn't
// declare KeyboardEvent as a member, even though the real jsdom window
// object it wraps has one -- this reaches it without an `any` escape.
function keyboardEventCtor(win: Window): typeof KeyboardEvent {
  return (win as unknown as { KeyboardEvent: typeof KeyboardEvent }).KeyboardEvent;
}

describe('the reliability strip inspector', () => {
  it('keyboard-steps through cells, wraps at neither end, and Escape returns to resting', async () => {
    const toggles = ALL_TOGGLES_ON;
    const payload = payloadFor(toggles);
    const range30d = 'error' in payload.reliability ? undefined : payload.reliability.ranges['30d'];
    if (!range30d) throw new Error('status-inspect: fixture missing a 30d reliability range');

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
    const stripEl = strip(card);
    const cellCount = range30d.cells.length;

    // Resting: the strip's own aria-valuenow is the last cell, and the
    // readout matches its label -- the "one function at the resting index"
    // contract (see Reliability.tsx).
    expect(stripEl.getAttribute('aria-valuenow')).toBe(String(cellCount - 1));
    const restingText = stripKeyText(card);
    expect(restingText).toContain(range30d.cells[cellCount - 1]?.label);

    const KeyboardEvent = keyboardEventCtor(mounted.window);
    const dispatch = (key: string) =>
      stripEl.dispatchEvent(new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true }));

    // Home jumps to the first cell.
    dispatch('Home');
    expect(stripEl.getAttribute('aria-valuenow')).toBe('0');
    expect(stripKeyText(card)).toContain(range30d.cells[0]?.label);

    // ArrowRight steps forward by one.
    dispatch('ArrowRight');
    expect(stripEl.getAttribute('aria-valuenow')).toBe('1');
    expect(stripKeyText(card)).toContain(range30d.cells[1]?.label);

    // ArrowLeft at the first cell stays clamped at 0, not negative.
    dispatch('ArrowLeft');
    dispatch('ArrowLeft');
    expect(stripEl.getAttribute('aria-valuenow')).toBe('0');

    // End jumps to the last cell.
    dispatch('End');
    expect(stripEl.getAttribute('aria-valuenow')).toBe(String(cellCount - 1));

    // ArrowRight at the last cell stays clamped there, not past it.
    dispatch('ArrowRight');
    expect(stripEl.getAttribute('aria-valuenow')).toBe(String(cellCount - 1));

    // Escape returns to resting -- indistinguishable from having never
    // interacted, per the resting-index assertions above.
    dispatch('Home');
    expect(stripEl.getAttribute('aria-valuenow')).toBe('0');
    dispatch('Escape');
    expect(stripEl.getAttribute('aria-valuenow')).toBe(String(cellCount - 1));
    expect(stripKeyText(card)).toBe(restingText);
  });

  it('switching the detail range drops an inspected index back to resting', async () => {
    const toggles = ALL_TOGGLES_ON;
    const payload = payloadFor(toggles);
    const range90d = 'error' in payload.reliability ? undefined : payload.reliability.ranges['90d'];
    if (!range90d) throw new Error('status-inspect: fixture missing a 90d reliability range');

    const mounted = mountStatus({
      toggles,
      tokens: { access: 'test-access-token' },
      routes: {
        data: [{ status: 200, body: payload }],
        metadata: [{ status: 200, body: metadata() }],
      },
    });
    await mounted.settled();

    const card = reliabilityCard(mounted.document);
    const rangeGroup = card.querySelector('[aria-label="Time range"]');
    const btn90d = Array.from(rangeGroup?.querySelectorAll('button') ?? []).find(
      (b) => b.textContent === '90d',
    );
    if (!btn90d) throw new Error('status-inspect: 90d range button not found');

    // Step off resting via keyboard, then switch range -- a stale index
    // pointing past the new (differently-sized) cell array would otherwise
    // survive the switch (see useResettableIndex's resetKey).
    const KeyboardEvent = keyboardEventCtor(mounted.window);
    strip(card).dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Home', bubbles: true, cancelable: true }),
    );
    expect(strip(card).getAttribute('aria-valuenow')).toBe('0');

    btn90d.click();

    const cellCount90d = range90d.cells.length;
    expect(strip(card).getAttribute('aria-valuenow')).toBe(String(cellCount90d - 1));
  });
});
