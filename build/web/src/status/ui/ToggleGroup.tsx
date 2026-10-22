/**
 * Relies on ordinary Preact reactivity: the caller updates `selected` state
 * in its own onSelect handler, and the re-render that follows recomputes
 * every button's aria-pressed from the new `selected` prop.
 */
export function ToggleGroup({
  items,
  selected,
  onSelect,
  ariaLabel,
}: {
  items: [string, string][];
  selected: string;
  onSelect: (value: string) => void;
  ariaLabel: string;
}) {
  return (
    <div class="toggle-group" role="group" aria-label={ariaLabel}>
      {items.map(([value, label]) => (
        <button
          key={value}
          type="button"
          aria-pressed={value === selected ? 'true' : 'false'}
          onClick={() => onSelect(value)}
        >
          {label}
        </button>
      ))}
    </div>
  );
}
