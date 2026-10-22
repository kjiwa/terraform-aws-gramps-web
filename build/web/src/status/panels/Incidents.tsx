import type { Change, Episode, InstanceRef, PanelError } from '../../generated/status-payload';
import { fmtDate, fmtDuration, fmtStamp } from '../../shared/format';
import { changeLabel, outcomeLabel, triggerLabel } from '../causes';
import { Card, ErrNote } from '../ui/Card';
import { StatRow } from '../ui/StatRow';

/** No card-local UI state -- the details/summary disclosure is native HTML
 * state, not JS-owned. */

interface IncidentStats {
  count: number;
  totalDown: number;
  unplannedDown: number;
  median: number | null;
  causeMix: string;
  instanceTypeCount: number;
}

// Client-side aggregation only -- no server change, no new disclosure.
// duration_s/cause/planned are already in the public allowlist, so every
// number below is derived entirely from data the public route already
// ships; new_instance.type is not, so it is naturally absent there --
// guarded on its own presence below, not branched on which route this
// render came from.
function incidentStats(d: Episode[]): IncidentStats {
  let totalDown = 0;
  let unplannedDown = 0;
  const durations: number[] = [];
  const causeCounts: Record<string, number> = {};
  const instanceTypes: Record<string, boolean> = {};
  d.forEach((ep) => {
    const dur = ep.duration_s || 0;
    totalDown += dur;
    if (!ep.planned) unplannedDown += dur;
    durations.push(dur);
    const cause = ep.cause || 'unknown';
    causeCounts[cause] = (causeCounts[cause] || 0) + 1;
    const type = ep.new_instance && ep.new_instance.type;
    if (type) instanceTypes[type] = true;
  });
  durations.sort((a, b) => a - b);
  const mid = Math.floor(durations.length / 2);
  const median =
    durations.length === 0
      ? null
      : durations.length % 2
        ? durations[mid]
        : ((durations[mid - 1] ?? 0) + (durations[mid] ?? 0)) / 2;
  const causeMix = Object.keys(causeCounts)
    .sort((a, b) => (causeCounts[b] ?? 0) - (causeCounts[a] ?? 0))
    .map((cause) => `${causeCounts[cause]} ${cause}`)
    .join(' · ');
  return {
    count: d.length,
    totalDown,
    unplannedDown,
    median: median ?? null,
    causeMix,
    instanceTypeCount: Object.keys(instanceTypes).length,
  };
}

// old.type -> new.type · az for a spot reclaim; new.type · az otherwise.
// Called only where new_instance is already known present. Each token is
// kept whole (types wrap only between tokens, the az never splits).
function instanceCell(ep: Episode) {
  const n = ep.new_instance as InstanceRef;
  const type = ep.old_instance ? `${ep.old_instance.type} → ${n.type}` : n.type;
  return (
    <>
      {type} · <span class="nowrap">{n.az}</span>
    </>
  );
}

// Dataset-level columns, as in the episodes table: the public route carries
// only at/kind/creator/outcome, the operator route everything.
function ChangesTable({ changes }: { changes: Change[] }) {
  const sorted = [...changes].sort((a, b) => (a.at < b.at ? 1 : -1));
  const hasDuration = sorted.some((c) => c.duration_s !== undefined);
  const hasOutage = sorted.some((c) => c.outage !== undefined);
  const hasId = sorted.some((c) => c.id);
  const hasDescription = sorted.some((c) => c.description);
  return (
    <details>
      <summary>{`${sorted.length} change${sorted.length === 1 ? '' : 's'} · most recent ${fmtDate(sorted[0]?.at)}`}</summary>
      <div class="table-scroll">
        <table class="tbl dense">
          <thead>
            <tr>
              <th>Time (UTC)</th>
              <th>What</th>
              <th>Trigger</th>
              <th>Outcome</th>
              {hasDuration && <th>Duration</th>}
              {hasOutage && <th>Outage</th>}
              {hasId && <th>Id</th>}
              {hasDescription && <th>Description</th>}
            </tr>
          </thead>
          <tbody>
            {sorted.map((c, i) => (
              <tr key={i}>
                <td class="nowrap" title={fmtDate(c.at)}>
                  {fmtStamp(c.at)}
                </td>
                <td class="nowrap">{changeLabel(c)}</td>
                <td class="nowrap">{triggerLabel(c)}</td>
                <td>{outcomeLabel(c)}</td>
                {hasDuration && <td>{fmtDuration(c.duration_s)}</td>}
                {hasOutage && (
                  <td>
                    {c.outage === undefined ? (
                      '—'
                    ) : (
                      <span class={c.outage ? 'badge badge-bad' : 'badge'}>
                        {c.outage ? 'yes' : 'no'}
                      </span>
                    )}
                  </td>
                )}
                {hasId && <td class="wrap">{c.id || '—'}</td>}
                {hasDescription && <td class="wrap">{c.description || '—'}</td>}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </details>
  );
}

export function Incidents({
  d,
  changes,
}: {
  d: Episode[] | PanelError | undefined;
  changes?: Change[] | PanelError | undefined;
}) {
  if (!d) return null;
  if ('error' in d) {
    return (
      <Card title="Incidents (1y)">
        <ErrNote message={d.error} />
      </Card>
    );
  }
  if (!Array.isArray(d) || d.length === 0) {
    return (
      <Card title="Incidents (1y)">
        <p class="note">No incidents in the last year.</p>
        {Array.isArray(changes) && changes.length > 0 && <ChangesTable changes={changes} />}
      </Card>
    );
  }

  const s = incidentStats(d);
  const stats: [string, string, string?][] = [
    [String(s.count), 'incidents'],
    [fmtDuration(s.totalDown), 'total downtime'],
    [fmtDuration(s.unplannedDown), 'unplanned'],
    [fmtDuration(s.median), 'median recovery'],
  ];
  // Distinct instance types is operator-only -- it only renders when at
  // least one episode actually carried new_instance.type, which is exactly
  // the signal for "am I looking at the authenticated payload."
  if (s.instanceTypeCount > 0) stats.push([String(s.instanceTypeCount), 'instance types']);

  const summaryText = `${d.length} incident${d.length === 1 ? '' : 's'} · most recent ${fmtDate(d[0]?.started)}`;

  // Dataset-level, not per-row: absent everywhere on the public route (its
  // allowlist drops both fields), present everywhere on the operator route
  // -- the same "the data decides" pattern incidentStats() uses above for
  // the instance-types tile.
  const hasEnded = d.some((ep) => ep.ended);
  const hasInstance = d.some((ep) => ep.new_instance);

  return (
    <Card title="Incidents (1y)">
      <StatRow items={stats} />
      {s.causeMix && <p class="note">{`Causes: ${s.causeMix}`}</p>}
      <details>
        <summary>{summaryText}</summary>
        <div class="table-scroll">
          <table class="tbl">
            <thead>
              <tr>
                <th>Started (UTC)</th>
                {hasEnded && <th>Ended (UTC)</th>}
                <th>Duration</th>
                <th>Cause</th>
                <th>Planned</th>
                {hasInstance && <th>Instance</th>}
              </tr>
            </thead>
            <tbody>
              {d.map((ep, i) => (
                <tr key={i}>
                  <td class="nowrap" title={fmtDate(ep.started)}>
                    {fmtStamp(ep.started)}
                  </td>
                  {hasEnded && (
                    <td class="nowrap" title={fmtDate(ep.ended)}>
                      {fmtStamp(ep.ended)}
                    </td>
                  )}
                  <td>{fmtDuration(ep.duration_s)}</td>
                  <td class="nowrap">{ep.cause || 'unknown'}</td>
                  <td>{ep.planned ? <span class="badge">planned</span> : '—'}</td>
                  {hasInstance && <td>{ep.new_instance ? instanceCell(ep) : '—'}</td>}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </details>
      {Array.isArray(changes) && changes.length > 0 && <ChangesTable changes={changes} />}
    </Card>
  );
}
