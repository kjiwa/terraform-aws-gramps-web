import type { Cost as CostData, PanelError } from '../../generated/status-payload';
import { fmtUsd } from '../../shared/format';
import { Bar } from '../ui/Bar';
import { Card, ErrNote } from '../ui/Card';
import { Kv } from '../ui/Kv';
import { StatRow } from '../ui/StatRow';

/** month_to_date_usd if present; falling back to summing top_services only
 * protects against a payload that somehow has one field without the other. */
function totalUsd(
  mtd: number | null | undefined,
  services: { service: string; amount_usd: number }[],
): number {
  if (mtd !== null && mtd !== undefined) return mtd;
  return services.reduce((sum, s) => sum + s.amount_usd, 0);
}

export function Cost({ d }: { d: CostData | PanelError | undefined }) {
  if (!d) return null;
  if ('error' in d) {
    return (
      <Card title="Cost (month to date)">
        <ErrNote message={d.error} />
      </Card>
    );
  }

  const mtd = d.month_to_date_usd;
  const budget = d.budget_usd;

  // Straight-line pacing (month-to-date / day-of-month x days-in-month),
  // not AWS's own Cost Explorer forecast -- see status.html's own comment
  // on why this simple projection is close enough without the extra grant
  // and API call. Labeled "projected," not "forecast," so it doesn't claim
  // a precision it doesn't have.
  let projected: number | null = null;
  if (budget) {
    const now = new Date();
    const dayOfMonth = now.getUTCDate();
    const daysInMonth = new Date(
      Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 0),
    ).getUTCDate();
    projected =
      mtd !== null && mtd !== undefined && dayOfMonth ? (mtd / dayOfMonth) * daysInMonth : null;
  }

  const services = d.top_services || [];
  let barRows: { service: string; amount_usd: number }[] = [];
  let maxAmount = 1;
  if (services.length) {
    // Collapse into "Other" using the true total, not just the sum of
    // what's shown: that folds in both the sub-1% services among the top
    // 10 *and* whatever sits beyond the top 10, in one honest bucket.
    const total = totalUsd(mtd, services);
    const threshold = total > 0 ? total * 0.01 : 0;
    const shown = services.filter((s) => s.amount_usd >= threshold);
    const shownSum = shown.reduce((sum, s) => sum + s.amount_usd, 0);
    const other = Math.max(0, total - shownSum);
    barRows = shown.map((s) => ({ service: s.service, amount_usd: s.amount_usd }));
    if (other > 0.005) barRows.push({ service: 'Other', amount_usd: other });
    maxAmount = barRows.reduce((m, row) => Math.max(m, row.amount_usd), 0) || 1;
  }

  return (
    <Card title="Cost (month to date)">
      {budget ? (
        <>
          <StatRow
            tight
            items={[
              [fmtUsd(mtd), 'spent'],
              [fmtUsd(budget), 'budget'],
              [projected === null ? '—' : fmtUsd(projected), 'projected'],
            ]}
          />
          <Bar
            fraction={(mtd || 0) / budget}
            tick={projected !== null ? projected / budget : null}
            ariaLabel={`${fmtUsd(mtd)} spent of ${fmtUsd(budget)} budget${
              projected !== null ? `, projected ${fmtUsd(projected)}` : ''
            }`}
          />
          <p class="note">Projected is straight-line pacing, not an AWS forecast.</p>
        </>
      ) : (
        <Kv pairs={[['Total', fmtUsd(mtd)]]} />
      )}
      {services.length > 0 && (
        <div>
          {barRows.map((row) => (
            <div key={row.service} class="bar-row">
              <div class="bar-label">{row.service}</div>
              <Bar
                fraction={row.amount_usd / maxAmount}
                ariaLabel={`${row.service}, ${fmtUsd(row.amount_usd)}`}
              />
              <div class="bar-value">{fmtUsd(row.amount_usd)}</div>
            </div>
          ))}
        </div>
      )}
    </Card>
  );
}
