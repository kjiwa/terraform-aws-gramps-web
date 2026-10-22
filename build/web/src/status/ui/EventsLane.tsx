import { CAUSE_CLASSES } from '../causes';
import { describeEvent, lanePercent, laneSpan, type LaneEvent, type LaneWindow } from '../events';
import { createScrubHandlers } from '../inspect';

const CLASS_COLOR = Object.fromEntries(CAUSE_CLASSES.map((c) => [c.id, c.colorVar]));

/**
 * Incidents and deliberate deploys on the reliability strip's own time axis.
 * Renders nothing for an empty window. One tab stop, stepped with the arrow
 * keys like the strip (see inspect.ts). The inspected index is the caller's: it
 * drives the strip's own readout line, so there is no tooltip of its own.
 * Every value is also in the Incidents panel's tables.
 */
export function EventsLane({
  window: w,
  events,
  index,
  onIndex,
}: {
  window: LaneWindow;
  events: LaneEvent[];
  index: number | null;
  onIndex: (i: number | null) => void;
}) {
  if (events.length === 0) return null;

  const onKeyDown = createScrubHandlers(events.length, index, onIndex).onKeyDown;
  const shown = index ?? events.length - 1;

  return (
    <div
      class="lane"
      role="slider"
      tabIndex={0}
      aria-label={`Events in this window: ${events.length}`}
      aria-valuemin={0}
      aria-valuemax={events.length - 1}
      aria-valuenow={shown}
      aria-valuetext={events[shown] ? describeEvent(events[shown]) : ''}
      onKeyDown={onKeyDown}
      onBlur={() => onIndex(null)}
      onPointerLeave={(e) => {
        if (e.pointerType !== 'touch') onIndex(null);
      }}
    >
      {events.map((e, i) => {
        const isActive = i === index;
        const span = e.kind === 'episode' ? laneSpan(w, e.at, e.durationS) : null;
        return e.kind === 'deploy' || !span ? (
          <span
            key={i}
            class={isActive ? 'lane-mark lane-deploy active' : 'lane-mark lane-deploy'}
            style={{ left: `${lanePercent(w, e.at)}%` }}
            onPointerEnter={() => onIndex(i)}
            onPointerDown={() => onIndex(i)}
          />
        ) : (
          <span
            key={i}
            class={isActive ? 'lane-mark lane-episode active' : 'lane-mark lane-episode'}
            style={{
              left: `min(${span.left}%, calc(100% - 4px))`,
              width: `${span.width}%`,
              background: `var(${CLASS_COLOR[e.cls]})`,
            }}
            onPointerEnter={() => onIndex(i)}
            onPointerDown={() => onIndex(i)}
          />
        );
      })}
    </div>
  );
}
