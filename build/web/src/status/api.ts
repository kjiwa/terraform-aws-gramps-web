import type { GETStatusDataResponse } from '../generated/status-payload';
import {
  accessToken,
  authGetApi,
  refresh,
  storedRefreshToken,
  type ApiResult,
} from '../shared/api';

export { accessToken, storedRefreshToken, type ApiResult };

/**
 * Status-specific fetch/classify helpers: port of status.html's
 * fetchStatusData() (824-916), fetchMetadata() (1908-1916), and
 * tryPublic() (1927-1952). Pure/localStorage-only; no DOM writes -- App.tsx
 * owns every DOM/state decision that follows a call here.
 */
const NO_TOKEN: ApiResult = {
  ok: false,
  status: 401,
  json: () => Promise.reject(new Error('status: fetch attempted on the no-token stub result')),
};

/**
 * X-Gramps-Token token/401/refresh/retry dance, for any gated /_status/*
 * path -- not Authorization, since CloudFront's OAC signing overwrites
 * Authorization on the way to the Lambda. Shared by fetchStatusData()
 * (/_status/data) and series.ts's useSeries() (/_status/series), so the
 * dance itself exists in exactly one place.
 */
export async function fetchStatusJson(path: string): Promise<ApiResult> {
  const t = accessToken() || (await refresh());
  if (!t) return NO_TOKEN;
  const req = (tok: string) =>
    fetch(path, {
      headers: { 'X-Gramps-Token': tok, Accept: 'application/json' },
      cache: 'no-store',
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

export async function fetchStatusData(): Promise<ApiResult> {
  return fetchStatusJson('/_status/data');
}

/**
 * Straight from the site's own /api/metadata/ with the visitor's own token,
 * not from /_status/data -- see status.py's module docstring on why DB/tree
 * data is deliberately not this Lambda's job. Returns only what
 * Deployment.tsx needs (gramps_version, server_version/
 * gramps_webapi_version).
 */
export interface Metadata {
  gramps_version?: string;
  server_version?: string;
  gramps_webapi_version?: string;
}

export async function fetchMetadata(): Promise<Metadata | null> {
  try {
    const r = await authGetApi('/metadata/');
    if (!r.ok) return null;
    return (await r.json()) as Metadata;
  } catch {
    return null; // independent of the main status fetch; fail quietly
  }
}

export type PublicData = Pick<
  GETStatusDataResponse,
  'reliability' | 'incidents' | 'changes' | 'interruptions' | 'spot_enabled'
>;

export type PublicResult =
  | { ok: true; data: PublicData }
  | { ok: false; reason: 'network-error' }
  | { ok: false; reason: 'not-configured' } // /_status/public 404s: the feature is off
  | { ok: false; reason: 'http-error'; status: number };

/**
 * For a signed-out visitor, or one whose role doesn't clear MIN_ROLE: try
 * the unauthenticated /_status/public route so the page shows *something*
 * instead of a bare "please sign in" prompt. Unlike the original's
 * tryPublic(), this returns a classified result instead of rendering
 * directly -- App.tsx owns the single-render invariant (exactly one of
 * "render public panels + gate below them" or "gate alone" happens) that
 * the original enforced by DOM side effect.
 */
export async function tryPublic(): Promise<PublicResult> {
  let r: Response;
  try {
    r = await fetch('/_status/public', { headers: { Accept: 'application/json' } });
  } catch {
    return { ok: false, reason: 'network-error' };
  }
  // 404 means the feature is off, not that this visitor did anything wrong.
  if (r.status === 404) return { ok: false, reason: 'not-configured' };
  // When public_reliability is off, this path has no CloudFront behavior at
  // all and falls through to the app origin, which answers every unrouted
  // path with the SPA shell -- 200, text/html, not a 404. Same meaning as
  // the Lambda's own 404: the feature is off.
  if (!(r.headers.get('content-type') || '').includes('json')) {
    return { ok: false, reason: 'not-configured' };
  }
  if (!r.ok) return { ok: false, reason: 'http-error', status: r.status };
  let data: PublicData;
  try {
    data = (await r.json()) as PublicData;
  } catch {
    return { ok: false, reason: 'http-error', status: r.status };
  }
  return { ok: true, data };
}
