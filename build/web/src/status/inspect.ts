import { useState } from 'preact/hooks';

/**
 * Shared scrub primitive: the reliability strip and every LineChart place
 * their samples the same way (LineChart.tsx's buildSvg puts sample `i` of
 * `count` at `((i + 0.5) / count) * w`; `.strip` renders `count` equal
 * `flex: 1` cells), so inverting one for "nearest index" and solving the
 * other for "containing cell" are the identical expression -- there is
 * exactly one formula for both surface kinds.
 */
export function indexFromPointer(clientX: number, rect: DOMRect, count: number): number {
  if (count <= 0 || rect.width <= 0) return 0;
  const raw = Math.round(((clientX - rect.left) / rect.width) * count - 0.5);
  return Math.max(0, Math.min(count - 1, raw));
}

export interface ScrubHandlers {
  onPointerMove: (e: PointerEvent) => void;
  onPointerDown: (e: PointerEvent) => void;
  onPointerLeave: (e: PointerEvent) => void;
  onKeyDown: (e: KeyboardEvent) => void;
}

/**
 * The pure event-handling core, shared by the strip (via useInspector below)
 * and LineChart's own overlay (called directly with a controlled index/
 * setter -- LineChart's inspected index lives in whichever panel renders
 * it, not in a hook LineChart owns itself, since the panel also needs the
 * index to build its own readout text). One implementation of the
 * pointer-vs-touch and keyboard-stepping rules, so neither surface has to
 * duplicate them.
 */
export function createScrubHandlers(
  count: number,
  index: number | null,
  setIndex: (i: number | null) => void,
): ScrubHandlers {
  function fromEvent(e: PointerEvent): number {
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
    return indexFromPointer(e.clientX, rect, count);
  }

  return {
    onPointerMove(e) {
      setIndex(fromEvent(e));
    },
    // A tap that never moves fires pointerdown with no pointermove after it
    // -- without this, a plain tap (no drag) would never register.
    onPointerDown(e) {
      setIndex(fromEvent(e));
    },
    // A touch pointer fires pointerleave immediately after pointerup
    // (implicit capture release); only a mouse actually "leaves" in the
    // sense this handler means to catch -- resetting unconditionally would
    // make every tap's value flash and vanish instead of staying pinned.
    onPointerLeave(e) {
      if (e.pointerType === 'touch') return;
      setIndex(null);
    },
    onKeyDown(e) {
      if (count <= 0) return;
      const current = index ?? count - 1;
      switch (e.key) {
        case 'ArrowLeft':
          e.preventDefault();
          setIndex(Math.max(0, current - 1));
          break;
        case 'ArrowRight':
          e.preventDefault();
          setIndex(Math.min(count - 1, current + 1));
          break;
        case 'Home':
          e.preventDefault();
          setIndex(0);
          break;
        case 'End':
          e.preventDefault();
          setIndex(count - 1);
          break;
        case 'Escape':
          e.preventDefault();
          setIndex(null);
          break;
      }
    },
  };
}

/**
 * index state that drops back to resting (null) whenever resetKey changes
 * -- a range switch or a pan -- so an
 * inspected index never keeps pointing into a differently-sized array
 * after the underlying data swaps out from under it. Exported on its own
 * for LineChart callers (Host/Assistant/Reliability's latency chart), which
 * hold this same shape of state themselves so it can also drive their own
 * readout text; useInspector below is the strip's version, which also
 * needs the handlers bundled in since the strip owns its own scrub surface
 * directly rather than delegating to LineChart.
 *
 * Resets synchronously during render (the "adjusting state when a prop
 * changes" pattern), not via useEffect: Preact defers effects to a later
 * frame, so an effect-based reset would leave a stale index -- and
 * therefore a stale readout -- visible for one paint after a range switch,
 * and would desync main.tsx's own `options.debounceRendering = (cb) =>
 * cb()` override, which exists specifically so a real `.click()`'s visible
 * effect is synchronous (see that file's comment). Calling setState mid-
 * render is intentional here: it bails out of the current render and
 * commits the corrected value immediately, before anything paints.
 */
export function useResettableIndex(resetKey: unknown): [number | null, (i: number | null) => void] {
  const [prevKey, setPrevKey] = useState(resetKey);
  const [index, setIndex] = useState<number | null>(null);
  if (prevKey !== resetKey) {
    setPrevKey(resetKey);
    setIndex(null);
    return [null, setIndex];
  }
  return [index, setIndex];
}

export interface Inspector extends ScrubHandlers {
  index: number | null;
}

/** The reliability strip's own scrub state: resettable index plus the handlers bound to it. */
export function useInspector(count: number, resetKey: unknown): Inspector {
  const [index, setIndex] = useResettableIndex(resetKey);
  return { index, ...createScrubHandlers(count, index, setIndex) };
}
