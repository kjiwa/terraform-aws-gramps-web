import type {
  Deployment as DeploymentData,
  DeploymentSummary,
  Image,
  PanelError,
} from '../../generated/status-payload';
import { fmtDate } from '../../shared/format';
import { Card, ErrNote } from '../ui/Card';
import { Kv, type KvValue } from '../ui/Kv';

/**
 * meta is /api/metadata/, fetched alongside the main status call and passed
 * down from App -- see fetchMetadata()'s comment on why it's a third,
 * independent source.
 */
export interface DeploymentMeta {
  gramps_version?: string;
  server_version?: string;
  gramps_webapi_version?: string;
}

// 71-char digest ("sha256:" + 64 hex) fits no column on this page;
// truncated to a recognizable prefix/suffix with the full value in title,
// same "shorten the display, keep the fact" pattern as the git SHA cells
// below.
function truncateDigest(digest: string | null): KvValue {
  const m = /^(sha256:)([0-9a-f]+)$/.exec(digest || '');
  if (!m || (m[2]?.length ?? 0) <= 20) return digest;
  const short = `${m[1]}${m[2]?.slice(0, 10)}…${m[2]?.slice(-6)}`;
  return <span title={digest ?? undefined}>{short}</span>;
}

// Same "shorten the display, keep the fact" link pattern used for the AMI's
// own commit cell below -- both describe commits in the one repo the page
// runs against, so both share this helper and its source_repo argument.
function commitCell(repo: string, sha: string | null | undefined): KvValue {
  if (!sha) return null;
  const short = sha.slice(0, 10);
  return <a href={`https://github.com/${repo}/commit/${sha}`}>{short}</a>;
}

function depBlock(label: string, dep: DeploymentSummary, repo: string) {
  if (!dep) {
    return (
      <div>
        <h4>{label}</h4>
        <p class="note">Not available.</p>
      </div>
    );
  }
  return (
    <div>
      <h4>{label}</h4>
      <Kv
        pairs={[
          ['ID', dep.id],
          ['Status', dep.status],
          ['Created', fmtDate(dep.create_time)],
          ['Commit', commitCell(repo, dep.commit)],
        ]}
      />
    </div>
  );
}

// meta is /api/metadata/ -- a third version alongside this block's own
// Tags/Digest, naming what's actually running inside the image rather than
// just which tag was pushed.
function imageBlock(img: Image | PanelError | undefined, repo: string) {
  if (!img || 'error' in img) {
    return (
      <div>
        <h4>Machine image</h4>
        <p class="note">{(img && 'error' in img && img.error) || 'Not available.'}</p>
      </div>
    );
  }
  // Base: the AMI this one was built from, described rather than just IDed
  // -- falls back to the build-time name tag, then to a bare dash, never to
  // the raw source AMI id itself.
  const base = img.source_ami_description || img.source_ami_name || null;
  return (
    <div>
      <h4>Machine image</h4>
      <Kv
        pairs={[
          ['Name', img.name],
          ['AMI', img.id],
          ['Built', fmtDate(img.creation_date)],
          ['Commit', commitCell(repo, img.git_sha)],
          ['Base', base],
        ]}
      />
    </div>
  );
}

export function Deployment({
  d,
  image,
  meta,
  repo,
}: {
  d: DeploymentData | PanelError | undefined;
  image: Image | PanelError | undefined;
  meta: DeploymentMeta | null;
  repo: string;
}) {
  if (!d) return null;
  if ('error' in d) {
    return (
      <Card title="Deployment">
        <ErrNote message={d.error} />
      </Card>
    );
  }

  // Same deployment ID for both: show it once, with a note on the heading,
  // instead of two identical blocks.
  const sameDeployment = !!(
    d.latest &&
    d.latest_succeeded &&
    d.latest.id === d.latest_succeeded.id
  );

  const containerRows: [string, KvValue][] = [];
  if (d.ecr_latest_image) {
    containerRows.push(
      ['Tags', (d.ecr_latest_image.tags || []).join(', ')],
      ['Digest', truncateDigest(d.ecr_latest_image.digest)],
      ['Pushed', fmtDate(d.ecr_latest_image.pushed_at)],
    );
    if (meta && meta.gramps_version) containerRows.push(['Gramps', meta.gramps_version]);
    const apiVersion = meta && (meta.server_version || meta.gramps_webapi_version);
    if (apiVersion) containerRows.push(['API', apiVersion]);
  }

  return (
    <Card title="Deployment">
      <div class="subgrid">
        {imageBlock(image, repo)}
        {d.ecr_latest_image && (
          <div>
            <h4>Container image</h4>
            <Kv pairs={containerRows} />
          </div>
        )}
        {depBlock(sameDeployment ? 'Rollout · latest succeeded' : 'Rollout', d.latest, repo)}
        {!sameDeployment && depBlock('Rollout · latest succeeded', d.latest_succeeded, repo)}
      </div>
      {!d.ecr_latest_image && d.ecr_error && <ErrNote message={d.ecr_error} />}
    </Card>
  );
}
