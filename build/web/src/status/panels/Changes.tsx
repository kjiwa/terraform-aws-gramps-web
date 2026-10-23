import { useState } from 'preact/hooks';
import type { Change, PanelError } from '../../generated/status-payload';
import { fmtDate, fmtDuration, fmtStamp } from '../../shared/format';
import { changeLabel, isDeliberateChange, outcomeLabel, triggerLabel } from '../causes';
import { Card, ErrNote } from '../ui/Card';
import { ToggleGroup } from '../ui/ToggleGroup';

type Filter = 'deliberate' | 'all';

const FILTERS: [string, string][] = [
  ['deliberate', 'Deliberate'],
  ['all', 'All'],
];

function outcomeBadge(c: Change) {
  const failed = c.outcome === 'failed' || c.outcome === 'rollback-failed';
  return <span class={failed ? 'badge badge-bad' : 'badge'}>{outcomeLabel(c)}</span>;
}

// Dataset-level columns: the public route carries only at/kind/creator/
// outcome, the operator route everything. Trigger only means something once
// Auto Scaling launches are listed, so it follows the filter.
function ChangesTable({ changes, withTrigger }: { changes: Change[]; withTrigger: boolean }) {
  const hasDuration = changes.some((c) => c.duration_s !== undefined);
  const hasOutage = changes.some((c) => c.outage !== undefined);
  const hasId = changes.some((c) => c.id);
  return (
    <details>
      <summary>{`${changes.length} change${changes.length === 1 ? '' : 's'} · most recent ${fmtDate(changes[0]?.at)}`}</summary>
      <div class="table-scroll">
        <table class="tbl dense">
          <thead>
            <tr>
              <th>Time (UTC)</th>
              <th>Change</th>
              {withTrigger && <th>Trigger</th>}
              <th>Outcome</th>
              {hasDuration && <th>Duration</th>}
              {hasOutage && <th>Outage</th>}
              {hasId && <th>Id</th>}
            </tr>
          </thead>
          <tbody>
            {changes.map((c, i) => (
              <tr key={i} title={c.description || undefined}>
                <td class="nowrap" title={fmtDate(c.at)}>
                  {fmtStamp(c.at)}
                </td>
                <td class="nowrap">{changeLabel(c)}</td>
                {withTrigger && <td class="nowrap">{triggerLabel(c)}</td>}
                <td>{outcomeBadge(c)}</td>
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
                {hasId && <td class="wrap mono">{c.id || '—'}</td>}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </details>
  );
}

export function Changes({ d }: { d: Change[] | PanelError | undefined }) {
  const [filter, setFilter] = useState<Filter>('deliberate');
  if (!d) return null;
  if ('error' in d) {
    return (
      <Card title="Changes">
        <ErrNote message={d.error} />
      </Card>
    );
  }
  if (!Array.isArray(d) || d.length === 0) {
    return (
      <Card title="Changes">
        <p class="note">No changes in the last year.</p>
      </Card>
    );
  }

  const sorted = [...d].sort((a, b) => (a.at < b.at ? 1 : -1));
  const deliberate = sorted.filter(isDeliberateChange);
  // The public route lists deliberate changes only, so there is nothing to flip.
  const filterable = deliberate.length < sorted.length;
  const all = filterable && filter === 'all';
  return (
    <Card title="Changes">
      {filterable && (
        <ToggleGroup
          items={FILTERS}
          selected={filter}
          onSelect={(v) => setFilter(v as Filter)}
          ariaLabel="Changes listed"
        />
      )}
      <div aria-live="polite">
        <ChangesTable changes={all ? sorted : deliberate} withTrigger={all} />
      </div>
    </Card>
  );
}
