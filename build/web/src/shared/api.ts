/**
 * Token storage and authenticated-fetch helpers shared by every page that
 * talks to the Gramps Web API under this origin: the status page (its own
 * X-Gramps-Token calls to /_status/data stay in src/status/api.ts, since
 * that shape is status-specific).
 *
 * Same-origin: this page and the Gramps Web SPA share an origin, so the
 * access/refresh tokens the SPA writes to localStorage are readable here.
 */
const API = '/api';

export function accessToken(): string | null {
  return localStorage.getItem('access_token');
}

export function storedRefreshToken(): string | null {
  return localStorage.getItem('refresh_token');
}

let refreshInFlight: Promise<string | null> | null = null;

/**
 * Single-flight refresh: concurrent callers (e.g. parallel requests
 * hitting a just-expired token at once) share one in-flight
 * POST, since the endpoint is rate limited to 1/second.
 */
export function refresh(): Promise<string | null> {
  if (refreshInFlight) return refreshInFlight;
  refreshInFlight = (async () => {
    const rt = storedRefreshToken();
    if (!rt) return null;
    const r = await fetch(`${API}/token/refresh/`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${rt}`, Accept: 'application/json' },
    });
    if (!r.ok) return null;
    const d = (await r.json()) as { access_token?: string };
    if (!d.access_token) return null;
    localStorage.setItem('access_token', d.access_token);
    return d.access_token;
  })();
  void refreshInFlight.finally(() => {
    refreshInFlight = null;
  });
  return refreshInFlight;
}

/**
 * A real fetch Response, or this exact no-token stub -- every caller checks
 * `status === 401` first, which is only ever true on the stub or on a real
 * 401 response, and returns before reading a body either way, so its
 * json() is unreachable in practice; it still throws if ever called by
 * mistake.
 */
export type ApiResult = Response | { ok: false; status: 401; json(): Promise<unknown> };

const NO_TOKEN: ApiResult = {
  ok: false,
  status: 401,
  json: () => Promise.reject(new Error('api: fetch attempted on the no-token stub result')),
};

/**
 * Authenticated GET against this site's own /api/*, with one transparent
 * refresh+retry on 401. `accept` varies by caller: JSON for most endpoints,
 * `text/plain` for the GEDCOM export, an image Accept list for thumbnails.
 */
export async function authGetApi(path: string, accept = 'application/json'): Promise<ApiResult> {
  const t = accessToken() || (await refresh());
  if (!t) return NO_TOKEN;
  const req = (tok: string) =>
    fetch(`${API}${path}`, {
      headers: { Authorization: `Bearer ${tok}`, Accept: accept },
    });
  let r = await req(t);
  if (r.status === 401) {
    const cur = accessToken();
    const nt = cur && cur !== t ? cur : await refresh();
    if (!nt) return NO_TOKEN;
    r = await req(nt);
  }
  return r;
}
