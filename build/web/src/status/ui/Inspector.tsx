import type { ComponentChildren } from 'preact';

/**
 * The pinned scrub readout shared by the reliability strip and every
 * LineChart's overlay (see inspect.ts). aria-hidden, deliberately not a
 * live region: every string this can show is already announced by its own
 * scrub surface's role="slider" aria-valuetext (see Reliability/Host/
 * Assistant.tsx and LineChart.tsx) -- a live region on top of that would
 * double-speak the same value. This is the visual channel only.
 *
 * cls defaults to "chart-key" -- the three chart-adjacent readouts (Host,
 * Assistant, Reliability's latency chart) reuse that pre-existing class
 * unchanged, matching status.css's styling and its `.chart-key + .stat-row`
 * spacing rule. Reliability's strip readout passes "strip-key" instead: the
 * strip already has its own chart-key sibling below it in the same card, so
 * both need distinct classes or `.chart-key` would resolve to two elements
 * per card (see status.css for the shared ruleset the two ship together).
 */
export function Inspector({
  children,
  cls = 'chart-key',
}: {
  children: ComponentChildren;
  cls?: string;
}) {
  return (
    <p class={cls} aria-hidden="true">
      {children}
    </p>
  );
}
