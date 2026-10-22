export type GateKind = 'signin' | 'forbidden' | 'error';

export interface GateState {
  kind: GateKind;
  extra?: string | number;
}

export function Gate({ kind, extra }: GateState) {
  let h: string;
  let p: string;
  let showBtn = true;
  if (kind === 'signin') {
    h = 'Please sign in';
    p = 'Sign in to the family tree, then come back to this page.';
  } else if (kind === 'forbidden') {
    h = 'Insufficient permissions';
    p = `Viewing this page requires the ${extra || 'owner'} role or above. Signed-in role is not enough.`;
    showBtn = false;
  } else {
    h = "Couldn't load status";
    p = `The server returned an error${extra ? ` (${extra})` : ''}. Please try again shortly.`;
    showBtn = false;
  }
  return (
    <div>
      <h2>{h}</h2>
      <p>{p}</p>
      {showBtn && (
        <a class="btn" href="/">
          Open the family tree
        </a>
      )}
    </div>
  );
}
