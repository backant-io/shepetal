'use client';

import { useState } from 'react';

type Result = 'approved' | 'denied' | 'invalid' | 'signed_out' | 'error';

/** POST /api/device/approve with the web session: approve (or deny) the code the app shows. */
export async function decideDevice(
  userCode: string,
  approve: boolean,
  fetchImpl: typeof fetch = fetch,
): Promise<Result> {
  try {
    const res = await fetchImpl('/api/device/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ user_code: userCode, approve }),
    });
    if (res.ok) return approve ? 'approved' : 'denied';
    if (res.status === 401) return 'signed_out';
    if (res.status === 400 || res.status === 404) return 'invalid';
  } catch {
    // network failure
  }
  return 'error';
}

const MESSAGES: Record<Exclude<Result, 'approved'>, string> = {
  denied: 'Denied. The app was not signed in.',
  invalid: 'This code has expired or was already used. Start signing in again from the Shepetal app to get a new one.',
  signed_out: 'You were signed out. Reload the page and sign in again.',
  error: 'The code could not be approved. Try again in a moment.',
};

export function ApproveDevice({ userCode }: { userCode: string }) {
  const [code, setCode] = useState(userCode);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<Result | null>(null);

  if (result === 'approved') {
    return (
      <div role="status">
        <p className="display text-4xl">Approved.</p>
        <p className="mt-3 text-[var(--hush)]">Go back to Shepetal. It finishes signing in on its own.</p>
      </div>
    );
  }

  const decide = async (approve: boolean) => {
    setBusy(true);
    setResult(await decideDevice(code.trim(), approve));
    setBusy(false);
  };

  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        decide(true);
      }}
    >
      {userCode ? (
        <p className="display text-[clamp(2.5rem,9vw,4rem)] tracking-[0.08em]" aria-label={`Code ${userCode}`}>
          {userCode}
        </p>
      ) : (
        <label className="block">
          <span className="text-sm text-[var(--hush)]">The code shown in the app</span>
          <input
            name="user_code"
            value={code}
            onChange={(e) => setCode(e.target.value.toUpperCase())}
            placeholder="ABCD-EFGH"
            autoComplete="off"
            autoCapitalize="characters"
            spellCheck={false}
            required
            className="display mt-2 block w-full max-w-[16ch] rounded-xl bg-[var(--raised)] px-4 py-3 text-4xl tracking-[0.08em] shadow-[inset_0_0_0_1.5px_var(--line)]"
          />
        </label>
      )}
      <div className="mt-8 flex flex-wrap gap-3">
        <button type="submit" className="btn" disabled={busy}>
          {busy ? 'Approving…' : 'Approve'}
        </button>
        <button type="button" className="btn btn-quiet" disabled={busy} onClick={() => decide(false)}>
          Deny
        </button>
      </div>
      {result && (
        <p role="alert" className={`mt-4 text-sm ${result === 'denied' ? 'text-[var(--hush)]' : 'text-[var(--rec)]'}`}>
          {MESSAGES[result]}
        </p>
      )}
    </form>
  );
}
