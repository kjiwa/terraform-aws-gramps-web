import { ToggleGroup } from './ToggleGroup';

/**
 * Thin wrapper over ToggleGroup for the three range-only callers (Reliability
 * detail range, Host CPU/memory, Assistant tokens).
 */
export function RangeSelector({
  available,
  selected,
  onSelect,
}: {
  available: string[];
  selected: string;
  onSelect: (value: string) => void;
}) {
  return (
    <ToggleGroup
      items={available.map((k): [string, string] => [k, k])}
      selected={selected}
      onSelect={onSelect}
      ariaLabel="Time range"
    />
  );
}
