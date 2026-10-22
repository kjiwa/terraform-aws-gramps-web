import type { ComponentChildren } from 'preact';

/**
 * items: [value, label, title?, sub?] tuples; title is a hover-only attribute
 * on the tile, sub a secondary line under the label (so labels stay aligned
 * across a row). tight -> a smaller auto-fit minimum (see .stat-row.tight).
 */
export function StatRow({
  items,
  tight,
}: {
  items: [ComponentChildren, string, string?, string?][];
  tight?: boolean;
}) {
  return (
    <div class={tight ? 'stat-row tight' : 'stat-row'}>
      {items.map(([value, label, title, sub]) => (
        <div key={label} class="stat" title={title}>
          <div class="n">{value}</div>
          <div class="l">{label}</div>
          {sub && <div class="sub">{sub}</div>}
        </div>
      ))}
    </div>
  );
}
