/**
 * The expected `.card > h3` and `.section-head` sets for a given toggle
 * set, derived from App.tsx's render order and Section's gating behavior
 * (see ui/Section.tsx). Shared by status-matrix.test.ts (jsdom, all 64
 * combinations) and status-render.spec.ts (Playwright, 8 combinations) so
 * the two suites' notion of "what should be on screen" can't drift apart
 * from each other.
 */
import type { Toggles } from './shell.ts';

/**
 * "Data" and "Spend" only flush when backups/cost are on -- every other
 * section always has at least one card behind it (Reliability, Incidents,
 * Deployment, Host, and Storage are all required payload fields, never
 * gated by a toggle).
 */
export function expectedSections(t: Toggles): string[] {
  const sections = ['Service', 'Delivery'];
  if (t.backups) sections.push('Data');
  sections.push('Runtime');
  if (t.cost) sections.push('Spend');
  return sections;
}

/**
 * host_metrics merges into the Host/Storage cards (a chart, a meter)
 * rather than gating a card of its own -- see renderHost()'s and
 * renderStorage()'s comments -- so it is deliberately absent here.
 * public_reliability affects the /_status/public route, never the
 * authenticated card set.
 */
export function expectedCards(t: Toggles): string[] {
  const cards = ['Reliability', 'Incidents', 'Deployment', 'Changes'];
  if (t.backups) cards.push('Backups');
  cards.push('Host', 'Storage');
  if (t.assistant) cards.push('Assistant');
  if (t.cost) cards.push('Cost (month to date)');
  return cards;
}
