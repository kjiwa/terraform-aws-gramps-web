/**
 * A per-test ephemeral HTTP server for the Playwright suite: real layout,
 * real network requests, real same-origin fetch()/localStorage semantics --
 * none of which jsdom's mountStatus() (tests/support/mount.ts) can give a
 * chart or a responsive-layout assertion. Mirrors CloudFront's *routing*
 * (edge/cloudfront_primary.tf's exact-path behaviors), not the Lambda's
 * internals: GET /_status(/), GET /_status/config.js (the S3-served
 * per-deployment config, see status_assets.tf's aws_s3_object.status_config),
 * GET /_status/data (X-Gramps-Token gated), GET /_status/public (the app
 * origin's SPA-shell fallback when public_reliability is off -- there is no
 * CloudFront behavior for the path in that case, so the request falls
 * through the same as any other unrouted path; not a 404), GET /_status/series
 * (X-Gramps-Token gated), GET /api/metadata/, POST /api/token/refresh/. No
 * /api/users/-/ route: it's the Lambda's own outbound auth call, never
 * something the client fetches directly (see status.py's authenticate()).
 *
 * Listens on port 0 (an OS-assigned free port) and starts fresh per test,
 * so Playwright's fullyParallel stays honest: no shared global webServer
 * for tests to race each other's toggle sets on.
 */
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import type { RangeKey } from '../../src/status/ranges.ts';
import { degradedPayload, metadata, payloadFor, publicPayload, seriesFor } from './payload.ts';
import { disabledPanels, shellHtml, type Toggles } from './shell.ts';

export interface RouteOverride {
  status: number;
  body?: unknown;
}

export interface ServerOptions {
  toggles: Toggles;
  dataOverride?: RouteOverride;
  /** Answers only the first GET /_status/data; later requests take the normal path. */
  firstDataOverride?: RouteOverride;
  publicOverride?: RouteOverride;
  metadataOverride?: RouteOverride;
  refreshOverride?: RouteOverride;
  /** Overrides GET /_status/series regardless of its query string -- an
   * injectable 4xx/5xx for a pan-error test, same shape as the other
   * *Override options above. */
  seriesOverride?: RouteOverride;
}

export interface RunningServer {
  url: string;
  close(): Promise<void>;
}

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  const json = JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(json);
}

function sendHtml(res: ServerResponse, status: number, html: string): void {
  res.writeHead(status, {
    'Content-Type': 'text/html; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  res.end(html);
}

function sendJs(res: ServerResponse, status: number, js: string): void {
  res.writeHead(status, {
    'Content-Type': 'application/javascript; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  res.end(js);
}

/** What the real app origin answers for any path CloudFront doesn't route:
 * the SPA shell, 200 text/html -- never a 404. Stands in both for
 * /_status/public when public_reliability is off and for any other
 * genuinely unrouted path. */
function sendAppOriginFallback(res: ServerResponse): void {
  sendHtml(res, 200, '<!doctype html><html><body>gramps-web app shell stand-in</body></html>');
}

export function startStatusServer(opts: ServerOptions): Promise<RunningServer> {
  // spliceConfig: false -- the built shell already carries a real
  // <script src="/_status/config.js">, so this server serves that route for
  // real (below) rather than shellHtml() masking it with an inline splice.
  let firstDataPending = opts.firstDataOverride;
  const shell = shellHtml(opts.toggles, { spliceConfig: false });

  function handle(req: IncomingMessage, res: ServerResponse): void {
    const url = new URL(req.url ?? '/', 'http://localhost');
    const path = url.pathname;

    if (req.method === 'GET' && (path === '/_status' || path === '/_status/')) {
      sendHtml(res, 200, shell);
      return;
    }

    if (req.method === 'GET' && path === '/_status/config.js') {
      const config = { disabledPanels: disabledPanels(opts.toggles) };
      sendJs(res, 200, `window.gwConfig = ${JSON.stringify(config)};`);
      return;
    }

    if (req.method === 'GET' && path === '/_status/data') {
      if (firstDataPending) {
        const { status, body } = firstDataPending;
        firstDataPending = undefined;
        sendJson(res, status, body);
        return;
      }
      if (opts.dataOverride) {
        sendJson(res, opts.dataOverride.status, opts.dataOverride.body);
        return;
      }
      const token = req.headers['x-gramps-token'];
      if (!token) {
        sendJson(res, 401, { error: 'unauthorized' });
        return;
      }
      // payloadFor() already carries min_role/caller_role/gramps_web_version
      // from the fixture (data_response()'s own three caller-specific
      // fields, baked in at fixture-generation time rather than stitched on
      // per-request here -- this server has no real auth to derive a role
      // from).
      sendJson(res, 200, payloadFor(opts.toggles));
      return;
    }

    if (req.method === 'GET' && path === '/_status/series') {
      if (opts.seriesOverride) {
        sendJson(res, opts.seriesOverride.status, opts.seriesOverride.body);
        return;
      }
      const token = req.headers['x-gramps-token'];
      if (!token) {
        sendJson(res, 401, { error: 'unauthorized' });
        return;
      }
      const panel = url.searchParams.get('panel');
      const range = url.searchParams.get('range');
      const end = url.searchParams.get('end');
      if (!panel || !range || !end) {
        sendJson(res, 400, { error: 'panel, range, and end are required' });
        return;
      }
      sendJson(res, 200, seriesFor(opts.toggles, panel, range as RangeKey, end));
      return;
    }

    if (req.method === 'GET' && path === '/_status/public') {
      if (opts.publicOverride) {
        sendJson(res, opts.publicOverride.status, opts.publicOverride.body);
        return;
      }
      if (!opts.toggles.public_reliability) {
        sendAppOriginFallback(res);
        return;
      }
      sendJson(res, 200, publicPayload());
      return;
    }

    if (req.method === 'GET' && path === '/api/metadata/') {
      if (opts.metadataOverride) {
        sendJson(res, opts.metadataOverride.status, opts.metadataOverride.body);
        return;
      }
      if (!req.headers.authorization) {
        sendJson(res, 401, { error: 'unauthorized' });
        return;
      }
      sendJson(res, 200, metadata());
      return;
    }

    if (req.method === 'POST' && path === '/api/token/refresh/') {
      if (opts.refreshOverride) {
        sendJson(res, opts.refreshOverride.status, opts.refreshOverride.body);
        return;
      }
      if (!req.headers.authorization) {
        sendJson(res, 401, { error: 'unauthorized' });
        return;
      }
      sendJson(res, 200, { access_token: 'refreshed-access-token' });
      return;
    }

    sendAppOriginFallback(res);
  }

  const server: Server = createServer(handle);
  return new Promise((resolve, reject) => {
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const addr = server.address();
      if (addr === null || typeof addr === 'string') {
        reject(new Error('startStatusServer: expected a bound AddressInfo'));
        return;
      }
      resolve({
        url: `http://127.0.0.1:${addr.port}`,
        close: () => new Promise((res, rej) => server.close((err) => (err ? rej(err) : res()))),
      });
    });
  });
}

/** Re-exported so a degraded-panel Playwright test doesn't need a second import. */
export { degradedPayload };
