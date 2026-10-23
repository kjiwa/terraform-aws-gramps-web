import { createContext, type ComponentChildren } from 'preact';
import { useContext } from 'preact/hooks';

/** The page's data fetch, offered to any panel that reports a timed-out section. */
export const RetryContext = createContext<(() => void) | null>(null);

export function Card({ title, children }: { title: string; children?: ComponentChildren }) {
  return (
    <div class="card">
      <h3>{title}</h3>
      {children}
    </div>
  );
}

const TIMED_OUT = 'timed out';

export function ErrNote({ message }: { message: string }) {
  const retry = useContext(RetryContext);
  if (message !== TIMED_OUT || !retry) return <p class="err">{message}</p>;
  return (
    <p class="err">
      {"Didn't load in time. "}
      <button type="button" class="btn-retry" onClick={retry}>
        Retry
      </button>
    </p>
  );
}
