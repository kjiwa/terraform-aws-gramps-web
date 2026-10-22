import { fireEvent, render, screen } from '@testing-library/preact';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { Spot } from '../../src/status/panels/Spot.tsx';

afterEach(() => vi.useRealTimers());

describe('Spot panel clock', () => {
  it('reads now on every render, so a warning newer than the mount time counts once time has passed', () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-06-15T12:00:00Z'));
    const warnings = [{ time: '2026-06-15T12:30:00Z', instance_id: 'i-1', action: 'terminate' }];
    render(<Spot incidents={[]} interruptions={warnings} spotEnabled />);
    const reclaims = () => screen.getByText('Reclaims').previousElementSibling?.textContent;
    expect(reclaims()).toBe('0');

    vi.setSystemTime(new Date('2026-06-15T13:00:00Z'));
    fireEvent.click(screen.getByRole('button', { name: '90d' }));
    expect(reclaims()).toBe('1');
  });
});
