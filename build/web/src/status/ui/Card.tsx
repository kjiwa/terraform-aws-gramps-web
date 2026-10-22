import type { ComponentChildren } from 'preact';

export function Card({ title, children }: { title: string; children?: ComponentChildren }) {
  return (
    <div class="card">
      <h3>{title}</h3>
      {children}
    </div>
  );
}

export function ErrNote({ message }: { message: string }) {
  return <p class="err">{message}</p>;
}
