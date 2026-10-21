import { CAUSE_CLASSES } from '../causes';
import type { LaneEvent } from '../events';
import { LegendPair } from './LegendPair';

/** The lane's legend group: only the classes the window actually holds. Nothing for an empty lane. */
export function EventsLegend({ events }: { events: LaneEvent[] }) {
  if (events.length === 0) return null;
  const present = CAUSE_CLASSES.filter((c) =>
    events.some((e) => e.kind === 'episode' && e.cls === c.id),
  );
  const hasDeploy = events.some((e) => e.kind === 'deploy');
  return (
    <span class="legend-group wrapping">
      <span class="legend-lead">Events</span>
      {present.map((c) => (
        <LegendPair key={c.id} cls={c.swatch} label={c.label} />
      ))}
      {hasDeploy && <LegendPair cls="c-ink" label="Deploy" />}
    </span>
  );
}
