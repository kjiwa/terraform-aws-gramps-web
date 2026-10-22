import type { RefObject } from 'preact';
import { useEffect, useState } from 'preact/hooks';

export interface Size {
  w: number;
  h: number;
}

/**
 * The wrapper's pixel box, measured once on mount (deferred one rAF tick, so
 * the browser has laid it out) and again on every rAF-debounced window
 * resize. jsdom has no ResizeObserver even with pretendToBeVisual, hence the
 * resize listener. null until a non-zero box exists, so a chart draws
 * nothing rather than a degenerate viewBox. Shared by LineChart and
 * BarChart so both charts size themselves the same way.
 */
export function useChartSize(wrapRef: RefObject<HTMLElement | null>): Size | null {
  const [size, setSize] = useState<Size | null>(null);

  useEffect(() => {
    function measure(): void {
      const node = wrapRef.current;
      if (!node) return;
      const w = node.clientWidth;
      const h = node.clientHeight;
      if (!w || !h) return; // not yet laid out; a later resize retries
      setSize({ w, h });
    }

    const initialRaf = window.requestAnimationFrame(measure);

    let resizeRaf: number | null = null;
    function scheduleRedraw(): void {
      if (resizeRaf !== null) return;
      resizeRaf = window.requestAnimationFrame(() => {
        resizeRaf = null;
        measure();
      });
    }
    window.addEventListener('resize', scheduleRedraw);

    return () => {
      window.cancelAnimationFrame(initialRaf);
      if (resizeRaf !== null) window.cancelAnimationFrame(resizeRaf);
      window.removeEventListener('resize', scheduleRedraw);
    };
  }, [wrapRef]);

  return size;
}
