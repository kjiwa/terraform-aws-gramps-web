/**
 * A JSX child is either rendered or it isn't -- there is no "flush this
 * heading only if a sibling card ends up rendering" trick, unlike a
 * procedural renderer that can defer emitting a heading until it knows a
 * body follows. So the caller (App.tsx) must gate this heading with the same
 * truthiness check each grouped panel's own `if (!d) return null` already
 * uses: "does at least one panel in this section have data" -- otherwise a
 * section heading (e.g. "Spend") renders with nothing under it when every
 * panel in that section is disabled.
 */
export function Section({ title }: { title: string }) {
  return <h2 class="section-head">{title}</h2>;
}
