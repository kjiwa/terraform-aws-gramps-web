import { render } from 'preact';
import { act } from 'preact/test-utils';
import { afterEach, describe, expect, it } from 'vitest';
import { PanelBoundary } from '../../src/status/ui/PanelBoundary.tsx';

function Boom(): never {
  throw new Error('kaboom');
}

let host: HTMLElement;

afterEach(() => {
  render(null, host);
});

async function mount(ui: preact.ComponentChildren) {
  host = document.createElement('div');
  await act(() => render(ui, host));
  return host;
}

describe('PanelBoundary', () => {
  it('replaces a throwing panel with a titled error card and keeps siblings', async () => {
    const root = await mount(
      <>
        <PanelBoundary title="Host">
          <Boom />
        </PanelBoundary>
        <PanelBoundary title="Storage">
          <div class="card">
            <h3>Storage</h3>
            <p class="ok">fine</p>
          </div>
        </PanelBoundary>
      </>,
    );

    const cards = root.querySelectorAll('.card');
    expect(cards).toHaveLength(2);
    expect(cards[0]?.querySelector('h3')?.textContent).toBe('Host');
    expect(cards[0]?.querySelector('p.err')?.textContent).toBe(
      'Could not render this panel: kaboom',
    );
    expect(cards[1]?.querySelector('p.ok')?.textContent).toBe('fine');
  });

  it('clears the error card when the data it renders changes', async () => {
    let broken = true;
    function Maybe() {
      if (broken) throw new Error('bad poll');
      return <p class="ok">recovered</p>;
    }
    host = document.createElement('div');
    const view = (key: number) => (
      <PanelBoundary title="Host" resetKey={key}>
        <Maybe />
      </PanelBoundary>
    );
    await act(() => render(view(1), host));
    expect(host.querySelector('p.err')?.textContent).toContain('bad poll');

    broken = false;
    await act(() => render(view(1), host));
    expect(host.querySelector('p.err')).not.toBeNull();

    await act(() => render(view(2), host));
    expect(host.querySelector('p.ok')?.textContent).toBe('recovered');
    expect(host.querySelector('p.err')).toBeNull();
  });

  it('renders children untouched when nothing throws', async () => {
    const root = await mount(
      <PanelBoundary title="Host">
        <p class="ok">fine</p>
      </PanelBoundary>,
    );
    expect(root.querySelector('p.ok')?.textContent).toBe('fine');
    expect(root.querySelector('.err')).toBeNull();
  });
});
