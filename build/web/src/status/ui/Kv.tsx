import { Fragment, type ComponentChildren } from 'preact';

/**
 * Key-value list component. `value` may be a plain string/number (coerced to
 * text) or real JSX children (an anchor, a DocumentFragment-equivalent).
 */
export type KvValue = ComponentChildren | string | number | null | undefined;

export function Kv({ pairs }: { pairs: [string, KvValue][] }) {
  return (
    <dl class="kv">
      {pairs.map(([label, value]) => {
        const empty = value === null || value === undefined || value === '';
        return (
          <Fragment key={label}>
            <dt>{label}</dt>
            <dd>{empty ? '—' : value}</dd>
          </Fragment>
        );
      })}
    </dl>
  );
}
