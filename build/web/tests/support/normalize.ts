/**
 * Canonicalizes a rendered subtree's markup for `toMatchFileSnapshot()`
 * comparisons: sorts each element's attributes (insertion order is an
 * implementation detail of el(), not a rendering contract) and collapses
 * whitespace that sits purely between tags. Strips nothing else -- title,
 * aria-label, and class all participate in the snapshot, since
 * status.html's fmt*() family (fmtPct/fmtBytes/fmtDuration/fmtTs) writes
 * into exactly those places, and formatting drift in a future Preact port
 * is the whole thing this oracle exists to catch.
 */
export function normalizeHtml(root: Element): string {
  const clone = root.cloneNode(true) as Element;
  for (const el of clone.querySelectorAll('*')) sortAttributes(el);
  sortAttributes(clone);
  return collapseInterTagWhitespace(clone.innerHTML);
}

function sortAttributes(el: Element): void {
  const entries = Array.from(el.attributes, (a) => [a.name, a.value] as const).sort(([a], [b]) =>
    a.localeCompare(b),
  );
  for (const [name] of entries) el.removeAttribute(name);
  for (const [name, value] of entries) el.setAttribute(name, value);
}

// NBSP (code point 160), built from String.fromCharCode rather than
// typed as a literal byte in a regex -- both to keep the source
// unambiguous in diffs and because a literal NBSP here trips eslint's
// no-irregular-whitespace rule, which exists to catch exactly this
// character showing up *by accident*.
const NBSP = String.fromCharCode(160);

function collapseInterTagWhitespace(html: string): string {
  return html
    .split(NBSP)
    .join(' ')
    .replace(/>[ \t\n\r]+</g, '><')
    .trim();
}
