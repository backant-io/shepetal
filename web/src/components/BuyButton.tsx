'use client';

import { useState } from 'react';

/** POST /api/checkout (API.md) with the web session. The url to open, or what to tell the user. */
export async function startCheckout(fetchImpl: typeof fetch = fetch): Promise<{ url: string } | { error: string }> {
  try {
    const res = await fetchImpl('/api/checkout', { method: 'POST' });
    if (res.status === 401) return { error: 'You were signed out. Reload the page and sign in again.' };
    if (res.status === 409) return { error: 'You already own Shepetal. Reload the page to see it.' };
    const body = (await res.json().catch(() => ({}))) as { url?: unknown };
    if (res.ok && typeof body.url === 'string') return { url: body.url };
  } catch {
    // network failure: same message as a server error
  }
  return { error: 'Checkout did not open. Try again in a moment.' };
}

export function BuyButton({ quiet = false }: { quiet?: boolean }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  return (
    <div>
      <button
        type="button"
        className={quiet ? 'btn btn-quiet' : 'btn'}
        disabled={busy}
        onClick={async () => {
          setBusy(true);
          setError('');
          const r = await startCheckout();
          if ('url' in r) return window.location.assign(r.url);
          setError(r.error);
          setBusy(false);
        }}
      >
        {busy ? 'Opening checkout…' : 'Buy for $4.99'}
      </button>
      {error && (
        <p role="alert" className="mt-3 text-sm text-[var(--rec)]">
          {error}
        </p>
      )}
    </div>
  );
}
