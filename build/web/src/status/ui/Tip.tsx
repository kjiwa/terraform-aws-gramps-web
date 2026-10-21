import type { ComponentChildren } from 'preact';

/**
 * BarChart's floating readout, at the top of its positioned parent, on whichever side
 * of the anchor (`percent` of the parent's width) has more room. Inert
 * (pointer-events: none) and aria-hidden: every value it shows is already in
 * the target's aria-label and in the data table.
 */
export function Tip({ percent, children }: { percent: number; children: ComponentChildren }) {
  const p = Math.max(0, Math.min(100, percent));
  const style =
    p <= 50
      ? { top: 0, left: `calc(${p}% + var(--gw-space-4))` }
      : { top: 0, right: `calc(${100 - p}% + var(--gw-space-4))` };
  return (
    <div class="tip" aria-hidden="true" style={style}>
      {children}
    </div>
  );
}
