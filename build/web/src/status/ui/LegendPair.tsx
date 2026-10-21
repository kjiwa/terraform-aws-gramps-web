import type { ComponentChildren } from 'preact';
import { Swatch } from './Swatch';

export function LegendPair({ cls, label }: { cls: string; label: ComponentChildren }) {
  return (
    <span class="legend-pair">
      <Swatch cls={cls} />
      {label}
    </span>
  );
}
