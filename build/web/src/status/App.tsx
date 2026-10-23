import { render } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import {
  accessToken,
  fetchMetadata,
  fetchStatusData,
  storedRefreshToken,
  tryPublic,
  type ApiResult,
  type Metadata,
  type PublicData,
} from './api';
import type { GETStatusDataResponse } from '../generated/status-payload';
import { Gate, type GateKind, type GateState } from './gate';
import { Assistant } from './panels/Assistant';
import { Backups } from './panels/Backups';
import { Changes } from './panels/Changes';
import { Cost } from './panels/Cost';
import { Deployment } from './panels/Deployment';
import { Host } from './panels/Host';
import { Incidents } from './panels/Incidents';
import { Reliability } from './panels/Reliability';
import { Storage } from './panels/Storage';
import { RetryContext } from './ui/Card';
import { PanelBoundary } from './ui/PanelBoundary';
import { Section } from './ui/Section';

/**
 * Status application state machine. `#skeleton`, `#who`, and `#gate` are DOM
 * siblings of `#panels`, not descendants -- Preact's render() corrupts a
 * container that already holds foreign DOM, so this component owns them via
 * plain DOM calls/a second render() call in useEffects, and returns JSX only
 * for `#panels`' own content.
 */

type AppState =
  | { phase: 'loading' }
  | { phase: 'data'; data: GETStatusDataResponse; meta: Metadata | null }
  | { phase: 'public'; data: PublicData; gate: GateState }
  | { phase: 'gate'; gate: GateState };

/** tryPublic(gateKind, extra): the fetch+classify lives in api.ts, the
 * resulting DOM/state decision here. */
async function resolveTryPublic(gateKind: GateKind, extra?: string | number): Promise<AppState> {
  const result = await tryPublic();
  if (result.ok) return { phase: 'public', data: result.data, gate: { kind: gateKind, extra } };
  if (result.reason === 'network-error') return { phase: 'gate', gate: { kind: 'error' } };
  // 404: the feature is off, not that this visitor did anything wrong --
  // but it's still this call's own gateKind/extra that decides what the
  // visitor sees next.
  if (result.reason === 'not-configured') return { phase: 'gate', gate: { kind: gateKind, extra } };
  return { phase: 'gate', gate: { kind: 'error', extra: result.status } };
}

async function computeState(): Promise<AppState> {
  if (!accessToken() && !storedRefreshToken()) {
    return resolveTryPublic('signin');
  }
  let results: [ApiResult, Metadata | null];
  try {
    results = await Promise.all([fetchStatusData(), fetchMetadata()]);
  } catch {
    return { phase: 'gate', gate: { kind: 'error' } };
  }
  const [r, meta] = results;
  if (r.status === 401) return resolveTryPublic('signin');
  if (r.status === 403) {
    const body = (await r.json().catch(() => ({}))) as { required_role?: string };
    return resolveTryPublic('forbidden', body.required_role);
  }
  if (!r.ok) return { phase: 'gate', gate: { kind: 'error', extra: r.status } };
  let data: GETStatusDataResponse;
  try {
    data = (await r.json()) as GETStatusDataResponse;
  } catch {
    return { phase: 'gate', gate: { kind: 'error', extra: r.status } };
  }
  return { phase: 'data', data, meta };
}

async function loadState(): Promise<AppState> {
  try {
    return await computeState();
  } catch {
    return { phase: 'gate', gate: { kind: 'error' } };
  }
}

export function App() {
  const [state, setState] = useState<AppState>({ phase: 'loading' });

  useEffect(() => {
    let cancelled = false;
    void loadState().then((next) => {
      if (!cancelled) setState(next);
    });
    return () => {
      cancelled = true;
    };
  }, []);

  const retry = () => void loadState().then(setState);

  // Owns skeleton removal: the moment state transitions out of "loading",
  // remove #skeleton via a plain DOM call -- #skeleton is a dedicated sibling,
  // plainly removed, never touched by Preact's render().
  useEffect(() => {
    if (state.phase === 'loading') return;
    document.getElementById('skeleton')?.remove();
  }, [state.phase]);

  // #who is a sibling of #panels too (inside <header>), so it's set the
  // same imperative way. "loading" and "gate" (no public data) leave it
  // untouched, so it stays the empty string the static shell ships.
  useEffect(() => {
    const whoEl = document.getElementById('who');
    if (!whoEl) return;
    if (state.phase === 'data') {
      const { data } = state;
      whoEl.textContent =
        `Signed in as ${data.caller_role || '?'} · min role ${data.min_role || '?'}` +
        (data.gramps_web_version ? ` · Gramps Web ${data.gramps_web_version}` : '');
    } else if (state.phase === 'public') {
      whoEl.textContent = 'Public reliability snapshot';
    }
  }, [state]);

  // #gate is a third sibling. Gate is one-shot in the original too: once
  // shown, "hidden" is never restored, and no other phase calls this --
  // so a second, independent render() call (plain 'preact', not a
  // preact/compat portal -- measured ~2.85 KB gzipped heavier for a
  // feature this doesn't need) is exactly as correct as a portal here and
  // costs nothing extra in the bundle.
  useEffect(() => {
    if (state.phase !== 'public' && state.phase !== 'gate') return;
    const gateEl = document.getElementById('gate');
    if (!gateEl) return;
    render(<Gate kind={state.gate.kind} extra={state.gate.extra} />, gateEl);
    gateEl.classList.remove('hidden');
  }, [state]);

  if (state.phase === 'loading' || state.phase === 'gate') return null;

  if (state.phase === 'public') {
    // Deliberately no section heading: X    // incidents) needs no heading either way.
    return (
      <RetryContext.Provider value={retry}>
        <PanelBoundary resetKey={state.data} title="Reliability">
          <Reliability d={state.data.reliability} episodes={state.data.incidents} />
        </PanelBoundary>
        <PanelBoundary resetKey={state.data} title="Incidents">
          <Incidents
            d={state.data.incidents}
            interruptions={state.data.interruptions}
            spotEnabled={state.data.spot_enabled}
          />
        </PanelBoundary>
        <PanelBoundary resetKey={state.data} title="Changes">
          <Changes d={state.data.changes} />
        </PanelBoundary>
      </RetryContext.Provider>
    );
  }

  // Section order tells the page's story top to bottom: what visitors get
  // (Service), how it ships (Delivery), what it holds (Data), what it runs
  // on (Runtime), what it costs (Spend). Data/Spend disappear entirely
  // when their one panel is off (backups/cost are optional payload keys);
  // Service/Delivery/Runtime always have at least one required panel, so
  // their headings render unconditionally.
  const { data, meta } = state;
  return (
    <RetryContext.Provider value={retry}>
      <Section title="Service" />
      <PanelBoundary resetKey={state.data} title="Reliability">
        <Reliability d={data.reliability} episodes={data.incidents} canPan />
      </PanelBoundary>
      <PanelBoundary resetKey={state.data} title="Incidents">
        <Incidents
          d={data.incidents}
          interruptions={data.interruptions}
          spotEnabled={data.spot_enabled}
          operator
        />
      </PanelBoundary>

      <Section title="Delivery" />
      <PanelBoundary resetKey={state.data} title="Deployment">
        <Deployment d={data.deployment} image={data.image} meta={meta} repo={data.source_repo} />
      </PanelBoundary>
      <PanelBoundary resetKey={state.data} title="Changes">
        <Changes d={data.changes} />
      </PanelBoundary>

      {data.backups && (
        <>
          <Section title="Data" />
          <PanelBoundary resetKey={state.data} title="Backups">
            <Backups d={data.backups} />
          </PanelBoundary>
        </>
      )}

      <Section title="Runtime" />
      <PanelBoundary resetKey={state.data} title="Host">
        <Host d={data.host} m={data.host_metrics} canPan />
      </PanelBoundary>
      <PanelBoundary resetKey={state.data} title="Storage">
        <Storage d={data.storage} m={data.host_metrics} canPan />
      </PanelBoundary>
      {data.assistant && (
        <PanelBoundary resetKey={state.data} title="Assistant">
          <Assistant d={data.assistant} canPan />
        </PanelBoundary>
      )}

      {data.cost && (
        <>
          <Section title="Spend" />
          <PanelBoundary resetKey={state.data} title="Cost (month to date)">
            <Cost d={data.cost} />
          </PanelBoundary>
        </>
      )}
    </RetryContext.Provider>
  );
}
