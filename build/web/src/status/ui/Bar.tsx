/**
 * A level meter (fill against a track), shared by the budget meter, the
 * disk-used meter, and each row of the cost service-bar list. opts.tick draws
 * a second marker past the fill (the budget meter's projection); opts.fillVar
 * overrides the default --gw-chart-1 fill for a multi-row context where every
 * row would otherwise render in the identical color.
 */
export function Bar({
  fraction,
  tick,
  fillVar,
  ariaLabel,
}: {
  fraction: number;
  tick?: number | null;
  fillVar?: string;
  ariaLabel?: string;
}) {
  const f = Math.max(0, Math.min(1, isFinite(fraction) ? fraction : 0));
  const showTick = tick !== undefined && tick !== null && isFinite(tick);
  return (
    <div class="meter" role="img" aria-label={ariaLabel ?? ''}>
      <div
        class="meter-fill"
        style={
          fillVar
            ? { width: `${f * 100}%`, background: `var(${fillVar})` }
            : { width: `${f * 100}%` }
        }
      />
      {showTick && (
        <div class="meter-tick" style={{ left: `${Math.max(0, Math.min(1, tick)) * 100}%` }} />
      )}
    </div>
  );
}
