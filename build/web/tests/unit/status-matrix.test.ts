/**
 * All 64 combinations of the six deployment toggles, mounted against
 * status.html in jsdom. This is the only suite that would catch an
 * unexpected coupling between a payload toggle and the rendered card set
 * (e.g. a future change that makes host_metrics gate a whole card instead
 * of merging into Host/Storage) -- everything else in this repo assumes
 * that coupling is exactly what renderAll() documents (status.html:
 * 1867-1897) and tests a fixed toggle set instead. Single-digit seconds:
 * no layout, no charts, just presence/absence.
 */
import { describe, expect, it } from 'vitest';
import { expectedCards, expectedSections } from '../support/expected.ts';
import { mountStatus } from '../support/mount.ts';
import { payloadFor } from '../support/payload.ts';
import type { Toggles } from '../support/shell.ts';

const TOGGLE_KEYS = [
  'host_metrics',
  'cost',
  'backups',
  'assistant',
  'public_reliability',
] as const satisfies readonly (keyof Toggles)[];

function allCombinations(): Toggles[] {
  const combos: Toggles[] = [];
  for (let bits = 0; bits < 1 << TOGGLE_KEYS.length; bits++) {
    const toggles = {} as Toggles;
    for (const [i, key] of TOGGLE_KEYS.entries()) {
      toggles[key] = Boolean(bits & (1 << i));
    }
    combos.push(toggles);
  }
  return combos;
}

function label(t: Toggles): string {
  const on = TOGGLE_KEYS.filter((key) => t[key]);
  return on.length ? on.join(',') : '(all off)';
}

describe('status-matrix', () => {
  it.each(allCombinations().map((t) => [label(t), t] as const))('%s', async (_label, toggles) => {
    const mounted = mountStatus({
      toggles,
      tokens: { access: 'test-access-token' },
      routes: {
        data: [{ status: 200, body: payloadFor(toggles) }],
        metadata: [{ status: 200, body: {} }],
      },
    });
    await mounted.settled();

    expect(mounted.pageErrors).toEqual([]);
    expect(mounted.document.querySelectorAll('.sk')).toHaveLength(0);

    const cardTitles = Array.from(
      mounted.document.querySelectorAll('.card > h3'),
      (el) => el.textContent,
    );
    const sectionTitles = Array.from(
      mounted.document.querySelectorAll('.section-head'),
      (el) => el.textContent,
    );

    expect(cardTitles).toEqual(expectedCards(toggles));
    expect(sectionTitles).toEqual(expectedSections(toggles));
  });
});
