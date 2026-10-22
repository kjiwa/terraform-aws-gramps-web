import type {
  Backups as BackupsData,
  CompletionSummary,
  PanelError,
} from '../../generated/status-payload';
import { fmtDate, fmtDuration } from '../../shared/format';
import { Card, ErrNote } from '../ui/Card';
import { Kv, type KvValue } from '../ui/Kv';

function lockState(v: boolean | undefined): string {
  return v === true ? 'locked' : v === false ? 'unlocked' : 'lock state unknown';
}

// Only the parenthetical is nowrap, not the timestamp: at narrow widths the
// full "YYYY-MM-DD HH:MM:SS UTC" span is wider than the column itself, and a
// nowrap span can't be shrunk to fit -- forcing the whole page into
// horizontal scroll. Leaving the timestamp breakable means its worst case
// is a clean wrap between date and time, while the short parenthetical
// stays one unit so it never splits as "(34m" / "55s ago)".
function completedAt(comp: NonNullable<CompletionSummary>): KvValue {
  return (
    <>
      {fmtDate(comp.completed)} <span class="nowrap">{`(${fmtDuration(comp.age_s)} ago)`}</span>
    </>
  );
}

function localBlock(d: BackupsData) {
  if (!d.local) {
    return (
      <div>
        <h4>Local</h4>
        <p class="note">{d.vault_error || 'Not available.'}</p>
      </div>
    );
  }
  const loc = d.local;
  return (
    <div>
      <h4>Local</h4>
      <Kv
        pairs={[
          ['Vault', loc.name],
          ['Region', loc.region],
          ['Recovery points', loc.recovery_points],
          ['Lock', lockState(loc.locked)],
          ['Retention', d.retention_days == null ? null : `${d.retention_days}d`],
          ['Last completed', d.latest_backup ? completedAt(d.latest_backup) : null],
        ]}
      />
    </div>
  );
}

// A destination_error only ever accompanies an already-present
// d.destination, so the two cases below are mutually exclusive: "not
// configured" (no destination block at all) never needs to carry an error
// of its own.
function destinationBlock(d: BackupsData) {
  if (!d.destination) {
    return (
      <div>
        <h4>Off-site</h4>
        <p class="note">Not configured.</p>
      </div>
    );
  }
  const dest = d.destination;
  return (
    <div>
      <h4>Off-site</h4>
      <Kv
        pairs={[
          ['Vault', dest.name],
          ['Region', dest.region],
          ['Account', dest.account_id],
          ['Recovery points', dest.recovery_points],
          ['Lock', lockState(dest.locked)],
          ['Retention', d.remote_retention_days == null ? null : `${d.remote_retention_days}d`],
          ['Last completed', d.latest_copy ? completedAt(d.latest_copy) : null],
        ]}
      />
      {d.destination_error && <ErrNote message={d.destination_error} />}
    </div>
  );
}

export function Backups({ d }: { d: BackupsData | PanelError | undefined }) {
  if (!d) return null;
  if ('error' in d) {
    return (
      <Card title="Backups">
        <ErrNote message={d.error} />
      </Card>
    );
  }

  return (
    <Card title="Backups">
      <Kv
        pairs={[
          [
            'Mode',
            // A <wbr> here wouldn't help: the cron string is full of
            // ordinary spaces, each already a valid break point, so the
            // browser's greedy line-breaking lands mid-schedule
            // regardless. white-space: nowrap on the schedule span makes
            // it one unbreakable unit; the plain space text node before it
            // is the only point still allowed to wrap.
            <>
              {(d.mode || '—').replace(/_/g, '-')}
              {d.schedule && (
                <>
                  {' '}
                  <span class="nowrap">{`· ${d.schedule}`}</span>
                </>
              )}
            </>,
          ],
          [
            'Failures (7d)',
            d.failed_jobs_7d
              ? `${d.failed_jobs_7d} failed job${d.failed_jobs_7d === 1 ? '' : 's'}`
              : 'None',
          ],
        ]}
      />
      <div class="subgrid">
        {localBlock(d)}
        {destinationBlock(d)}
      </div>
      {d.backup_jobs_error && <ErrNote message={d.backup_jobs_error} />}
      {d.copy_jobs_error && <ErrNote message={d.copy_jobs_error} />}
      {d.failed_jobs_error && <ErrNote message={d.failed_jobs_error} />}
    </Card>
  );
}
