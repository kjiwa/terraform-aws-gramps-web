import type { ComponentChildren } from 'preact';
import { useEffect, useErrorBoundary, useRef } from 'preact/hooks';
import { Card, ErrNote } from './Card';

/**
 * Degrades one panel's render error to the same card + error note a
 * Lambda-reported section error gets, so siblings keep rendering. `title`
 * must match the panel's own Card title. `resetKey` is the data the panel
 * renders: a new value clears the error, so one bad poll does not stick.
 */
export function PanelBoundary({
  title,
  resetKey,
  children,
}: {
  title: string;
  resetKey?: unknown;
  children?: ComponentChildren;
}) {
  const [error, reset] = useErrorBoundary() as [unknown, () => void];
  const seenRef = useRef(resetKey);
  useEffect(() => {
    if (error && seenRef.current !== resetKey) reset();
    seenRef.current = resetKey;
  }, [error, reset, resetKey]);
  if (!error) return <>{children}</>;
  const reason = error instanceof Error ? error.message : 'unexpected error';
  return (
    <Card title={title}>
      <ErrNote message={`Could not render this panel: ${reason}`} />
    </Card>
  );
}
