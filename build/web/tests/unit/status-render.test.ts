/**
 * The bulk oracle: normalized #panels markup, snapshotted, for the four
 * shapes that matter most -- everything on, everything optional off,
 * degraded panels, and the signed-out public fallback. normalizeHtml()
 * (tests/support/normalize.ts) strips nothing, so drift in the fmt*()
 * family (fmtPct/fmtBytes/fmtDuration/fmtTs), a renamed card title, or an
 * attribute value quietly changing all show up as a snapshot diff.
 */
import { describe, expect, it } from 'vitest';
import { mountStatus } from '../support/mount.ts';
import { normalizeHtml } from '../support/normalize.ts';
import {
  degradedPayload,
  metadata,
  noRolloutCommitPayload,
  payloadFor,
  publicPayload,
} from '../support/payload.ts';
import { ALL_TOGGLES_OFF, ALL_TOGGLES_ON } from '../support/shell.ts';

function panelsOf(document: Document): Element {
  const panels = document.getElementById('panels');
  if (!panels) throw new Error('status-render: #panels missing from the mounted document');
  return panels;
}

// The Incidents card's first table: the episodes, ahead of its Changes table.
function incidentHeaders(document: Document): (string | null)[] {
  const card = [...panelsOf(document).querySelectorAll('.card')].find(
    (c) => c.querySelector('h3')?.textContent === 'Incidents (1y)',
  );
  return [...(card?.querySelector('.tbl')?.querySelectorAll('th') ?? [])].map(
    (th) => th.textContent,
  );
}

describe('status-render', () => {
  it('renders every panel with every optional toggle on', async () => {
    const mounted = mountStatus({
      toggles: ALL_TOGGLES_ON,
      tokens: { access: 'test-access-token' },
      routes: {
        data: [{ status: 200, body: payloadFor(ALL_TOGGLES_ON) }],
        metadata: [{ status: 200, body: metadata() }],
      },
    });
    await mounted.settled();
    expect(mounted.pageErrors).toEqual([]);

    // The operator route's Incidents table carries the two columns the
    // public allowlist strips (see the public-route assertions below).
    const headers = incidentHeaders(mounted.document);
    expect(headers).toEqual([
      'Started (UTC)',
      'Ended (UTC)',
      'Duration',
      'Cause',
      'Planned',
      'Instance',
    ]);

    // Both Rollout commits and the AMI's own commit link into source_repo --
    // three cells, one repo.
    const commitLinks = [...panelsOf(mounted.document).querySelectorAll('a[href*="/commit/"]')].map(
      (a) => (a as HTMLAnchorElement).href,
    );
    expect(commitLinks.length).toBe(3);
    expect(
      commitLinks.every((href) => href.startsWith('https://github.com/example/gramps-web/commit/')),
    ).toBe(true);

    await expect(normalizeHtml(panelsOf(mounted.document))).toMatchFileSnapshot(
      '__snapshots__/status-render.full.html',
    );
  });

  it('links the Machine image commit even when neither Rollout deployment resolves one', async () => {
    // The live state whenever the newest CodeDeploy executions were
    // Auto Scaling-triggered and deployment_commits() finds no pipeline
    // execution or same-revision deployment to inherit a SHA from: both
    // Rollout blocks degrade their Commit cell to --, but the AMI's own
    // git_sha is independent of that join and must still link.
    const mounted = mountStatus({
      toggles: ALL_TOGGLES_ON,
      tokens: { access: 'test-access-token' },
      routes: {
        data: [{ status: 200, body: noRolloutCommitPayload() }],
        metadata: [{ status: 200, body: metadata() }],
      },
    });
    await mounted.settled();
    expect(mounted.pageErrors).toEqual([]);

    const commitLinks = [...panelsOf(mounted.document).querySelectorAll('a[href*="/commit/"]')].map(
      (a) => (a as HTMLAnchorElement).href,
    );
    expect(commitLinks.length).toBe(1);
    expect(commitLinks[0]).toMatch(/^https:\/\/github\.com\/example\/gramps-web\/commit\//);
  });

  it('renders with every optional panel off', async () => {
    const mounted = mountStatus({
      toggles: ALL_TOGGLES_OFF,
      tokens: { access: 'test-access-token' },
      routes: {
        data: [{ status: 200, body: payloadFor(ALL_TOGGLES_OFF) }],
        metadata: [{ status: 200, body: {} }],
      },
    });
    await mounted.settled();
    expect(mounted.pageErrors).toEqual([]);
    await expect(normalizeHtml(panelsOf(mounted.document))).toMatchFileSnapshot(
      '__snapshots__/status-render.all-off.html',
    );
  });

  it('renders degraded panels with their own error note, siblings unaffected', async () => {
    const mounted = mountStatus({
      toggles: ALL_TOGGLES_ON,
      tokens: { access: 'test-access-token' },
      routes: {
        data: [
          {
            status: 200,
            body: degradedPayload(['reliability', 'backups'], 'ThrottlingException: Rate exceeded'),
          },
        ],
        metadata: [{ status: 200, body: metadata() }],
      },
    });
    await mounted.settled();
    expect(mounted.pageErrors).toEqual([]);
    await expect(normalizeHtml(panelsOf(mounted.document))).toMatchFileSnapshot(
      '__snapshots__/status-render.degraded.html',
    );
  });

  it('renders the public reliability fallback for a signed-out visitor', async () => {
    const mounted = mountStatus({
      toggles: ALL_TOGGLES_ON,
      routes: {
        public: [{ status: 200, body: publicPayload() }],
      },
    });
    await mounted.settled();
    expect(mounted.pageErrors).toEqual([]);

    // public_response()'s allowlist drops ended/new_instance at the
    // source, so both columns are absent -- not just empty -- on this route.
    const headers = incidentHeaders(mounted.document);
    expect(headers).toEqual(['Started (UTC)', 'Duration', 'Cause', 'Planned']);

    // No Deployment panel at all on the public route -- deployment never
    // reaches public_response(), so there is nothing to link.
    expect(panelsOf(mounted.document).querySelector('a[href*="/commit/"]')).toBeNull();

    await expect(normalizeHtml(panelsOf(mounted.document))).toMatchFileSnapshot(
      '__snapshots__/status-render.public.html',
    );
  });
});
