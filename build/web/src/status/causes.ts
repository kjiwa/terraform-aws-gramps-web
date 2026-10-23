import type { Change, Episode } from '../generated/status-payload';

/**
 * The one cause -> class -> color mapping the Incidents chart and its legend read. Spot reclaims are their own class
 * because they are the panel's subject; every other cause follows the
 * episode's own `planned` flag, which both payload routes carry.
 */
export type CauseClass = 'spot' | 'planned' | 'unplanned';

export const CAUSE_CLASSES: { id: CauseClass; label: string; colorVar: string; swatch: string }[] =
  [
    { id: 'spot', label: 'Spot reclaim', colorVar: '--gw-chart-2', swatch: 'c-chart2' },
    { id: 'planned', label: 'Planned', colorVar: '--gw-chart-3', swatch: 'c-chart3' },
    { id: 'unplanned', label: 'Unplanned', colorVar: '--gw-chart-1', swatch: 'c-chart1' },
  ];

export function causeClass(ep: Pick<Episode, 'cause' | 'planned'>): CauseClass {
  if (ep.cause === 'spot-reclaim') return 'spot';
  return ep.planned ? 'planned' : 'unplanned';
}

/** Mirrors DELIBERATE_DEPLOYMENT_CREATORS in lambda/status.py: a person or a CodeDeploy rollback, not an Auto Scaling launch. */
export const DELIBERATE_CREATORS = ['user', 'codeDeployRollback'];

export function isDeliberateDeploy(c: Pick<Change, 'kind' | 'creator'>): boolean {
  return c.kind === 'deploy' && c.creator !== null && DELIBERATE_CREATORS.includes(c.creator);
}

const TRIGGER_LABELS: Record<string, string> = {
  user: 'user',
  codeDeployRollback: 'rollback',
  autoscaling: 'autoscaling',
};

export function triggerLabel(c: Pick<Change, 'kind' | 'creator'>): string {
  if (c.kind === 'instance-refresh') return 'refresh';
  return (c.creator && TRIGGER_LABELS[c.creator]) || c.creator || '—';
}

export function changeLabel(c: Pick<Change, 'kind'>): string {
  return c.kind === 'deploy' ? 'deploy' : 'instance refresh';
}

export function outcomeLabel(c: Pick<Change, 'outcome'>): string {
  return c.outcome.replace('-', ' ');
}
