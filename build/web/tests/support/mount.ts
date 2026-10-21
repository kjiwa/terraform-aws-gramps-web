/**
 * Mounts the built status page end to end in jsdom against a plain-object
 * fetch stub -- no server, no network. `runScripts: 'dangerously'` plus
 * `pretendToBeVisual: true` is required: without the latter, the chart
 * code's `requestAnimationFrame` call throws and jsdom never finishes
 * parsing the bundle's inline script. jsdom has no global `fetch`/`Response`
 * of its own -- Node's own `Response` class is a different realm and
 * silently fails against jsdom's internals -- so every stubbed response
 * below is a hand-built `{ ok, status, json }` object, never the real
 * class.
 */
import { JSDOM, VirtualConsole } from 'jsdom';
import { shellHtml, type Toggles } from './shell.ts';

const PAGE_URL = 'https://status.example.test/_status';

// The one instant every mounted page's clock is frozen to. Only the Cost
// panel reads the wall clock at all (the month-to-date budget projection)
// -- everything else formats from
// payload-supplied ISO strings -- but freezing it here means every test
// that mounts the page gets a stable Cost snapshot without having to know
// that fact itself. Installed on the *page's* Date (in beforeParse, before
// any inline script runs), not the test runner's: vi.useFakeTimers()
// patches the test realm, which is a different global object than the one
// jsdom's runScripts executes against.
const FROZEN_NOW_ISO = '2026-06-15T12:00:00Z';

export type RouteResponse =
  { status: number; body?: unknown; contentType?: string } | 'network-error';

export interface MountRoutes {
  /** GET /_status/data responses, consumed in call order (last repeats). */
  data?: RouteResponse[];
  /** GET /_status/public responses, consumed in call order (last repeats). */
  public?: RouteResponse[];
  /** GET /api/metadata/ responses, consumed in call order (last repeats). */
  metadata?: RouteResponse[];
  /** POST /api/token/refresh/ responses, consumed in call order (last repeats). */
  refresh?: RouteResponse[];
  /**
   * GET /_status/series responses, consumed in call order (last repeats).
   * Query-string-agnostic, same as every other route stub here -- a pan test
   * asserts the request happened via `fetchCalls`, not by matching this stub's
   * response to the exact panel/range/end requested.
   */
  series?: RouteResponse[];
}

export interface MountTokens {
  access?: string;
  refresh?: string;
}

export interface MountOptions {
  toggles: Toggles;
  tokens?: MountTokens;
  routes?: MountRoutes;
}

export interface FetchCall {
  url: string;
  method: string;
}

export interface Mounted {
  window: Window;
  document: Document;
  fetchCalls: FetchCall[];
  pageErrors: string[];
  /** Polls until a rendered card or a non-empty #gate appears. */
  settled(timeoutMs?: number): Promise<void>;
}

function nextRoute(
  list: RouteResponse[] | undefined,
  callIndex: number,
  fallback: RouteResponse,
): RouteResponse {
  if (!list || list.length === 0) return fallback;
  return list[Math.min(callIndex, list.length - 1)] ?? fallback;
}

function toFetchResponse(route: RouteResponse): Promise<{
  ok: boolean;
  status: number;
  headers: { get(name: string): string | null };
  json: () => Promise<unknown>;
}> {
  if (route === 'network-error')
    return Promise.reject(new Error('mountStatus: simulated network error'));
  const { status, body, contentType = 'application/json' } = route;
  const isJson = contentType.includes('json');
  return Promise.resolve({
    ok: status >= 200 && status < 300,
    status,
    headers: {
      get: (name: string) => (name.toLowerCase() === 'content-type' ? contentType : null),
    },
    // A non-JSON contentType (the app origin's HTML fallback, in practice)
    // rejects the same way a real Response's json() does when the body
    // isn't valid JSON -- tryPublic()/computeState() must survive this, not
    // just the routes that hand back well-formed JSON.
    json: isJson
      ? () => Promise.resolve(body)
      : () => Promise.reject(new SyntaxError('mountStatus: body is not JSON')),
  });
}

export function mountStatus(opts: MountOptions): Mounted {
  const html = shellHtml(opts.toggles);
  const fetchCalls: FetchCall[] = [];
  const pageErrors: string[] = [];
  const callIndex = { data: 0, public: 0, metadata: 0, refresh: 0, series: 0 };

  const virtualConsole = new VirtualConsole();
  virtualConsole.on('jsdomError', (err: Error) => {
    pageErrors.push(err.message);
  });

  const dom = new JSDOM(html, {
    runScripts: 'dangerously',
    pretendToBeVisual: true,
    url: PAGE_URL,
    virtualConsole,
    beforeParse(window) {
      if (opts.tokens?.access) window.localStorage.setItem('access_token', opts.tokens.access);
      if (opts.tokens?.refresh) window.localStorage.setItem('refresh_token', opts.tokens.refresh);

      const RealDate = window.Date;
      const frozenMs = new RealDate(FROZEN_NOW_ISO).getTime();
      // Only status.html's own `new Date()` (renderCost()'s month-to-date
      // projection) needs to see the frozen instant; every other call site
      // parses a payload-supplied ISO string via `new Date(iso)` and must
      // keep working exactly as it does today (see fmtDate()). Typed
      // against Date's three real overloads, spread-forwarded rather than
      // cast through `any`, so this stays exhaustively type-checked instead
      // of trusting the constructor call blindly.
      class FrozenDate extends RealDate {
        constructor();
        constructor(value: number | string);
        constructor(
          year: number,
          month: number,
          date?: number,
          hours?: number,
          minutes?: number,
          seconds?: number,
          ms?: number,
        );
        constructor(
          ...args:
            [] | [number | string] | [number, number, number?, number?, number?, number?, number?]
        ) {
          if (args.length === 0) super(frozenMs);
          else if (args.length === 1) super(args[0]);
          else super(...args);
        }
        static override now(): number {
          return frozenMs;
        }
      }
      Object.defineProperty(window, 'Date', {
        value: FrozenDate,
        configurable: true,
        writable: true,
      });

      window.addEventListener('error', (ev: ErrorEvent) => {
        pageErrors.push(ev.error instanceof Error ? ev.error.message : String(ev.message));
      });

      const fetchStub = (input: unknown, init?: { method?: string }): Promise<unknown> => {
        const url = String(input);
        const method = init?.method ?? 'GET';
        fetchCalls.push({ url, method });

        if (url.startsWith('/_status/public')) {
          const route = nextRoute(opts.routes?.public, callIndex.public++, {
            status: 404,
            body: { error: 'not found' },
          });
          return toFetchResponse(route);
        }
        if (url.startsWith('/_status/data')) {
          const route = nextRoute(opts.routes?.data, callIndex.data++, { status: 200, body: {} });
          return toFetchResponse(route);
        }
        if (url.startsWith('/_status/series')) {
          const route = nextRoute(opts.routes?.series, callIndex.series++, {
            status: 404,
            body: { error: 'not found' },
          });
          return toFetchResponse(route);
        }
        if (url.startsWith('/api/metadata/')) {
          const route = nextRoute(opts.routes?.metadata, callIndex.metadata++, {
            status: 200,
            body: {},
          });
          return toFetchResponse(route);
        }
        if (url.startsWith('/api/token/refresh/')) {
          const route = nextRoute(opts.routes?.refresh, callIndex.refresh++, {
            status: 401,
            body: { error: 'no refresh token' },
          });
          return toFetchResponse(route);
        }
        return Promise.reject(new Error(`mountStatus: unhandled fetch ${method} ${url}`));
      };
      Object.defineProperty(window, 'fetch', {
        value: fetchStub,
        configurable: true,
        writable: true,
      });
    },
  });

  async function settled(timeoutMs = 2000): Promise<void> {
    await waitUntil(() => {
      // The static skeleton itself contains `.card > h3` markup (see
      // pages/status.html), so that alone can't distinguish "still showing
      // the skeleton" from "rendered." App.tsx's #skeleton-removal effect
      // fires on every transition out of the "loading" phase, which is
      // what removes every .sk node; that removal is the one event common
      // to all of them.
      return dom.window.document.querySelectorAll('.sk').length === 0;
    }, timeoutMs);
  }

  return {
    window: dom.window as unknown as Window,
    document: dom.window.document,
    fetchCalls,
    pageErrors,
    settled,
  };
}

/**
 * Polls `condition` until it holds. Tests await the state they assert on
 * rather than sleeping a fixed time, so a loaded machine only slows them
 * down instead of failing them. Reads the test runner's own Date,
 * deliberately: this loop runs in the Vitest realm, not the mounted page's,
 * so it must not see the frozen window.Date installed in mountStatus().
 */
export async function waitUntil(condition: () => boolean, timeoutMs = 2000): Promise<void> {
  const start = Date.now();
  while (!condition()) {
    if (Date.now() - start > timeoutMs) {
      throw new Error(`mountStatus: condition not met within ${timeoutMs}ms`);
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}
