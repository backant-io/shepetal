'use client';

import { useState } from 'react';

export type CheckoutPlan = 'lifetime' | 'monthly';

/** POST /api/checkout (API.md) with the web session and the plan. The url to open, or what to tell the user. */
export async function startCheckout(
  plan: CheckoutPlan,
  fetchImpl: typeof fetch = fetch,
): Promise<{ url: string } | { error: string }> {
  try {
    const res = await fetchImpl('/api/checkout', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ plan }),
    });
    if (res.status === 401) return { error: 'You were signed out. Reload the page and sign in again.' };
    if (res.status === 409) {
      const body = (await res.json().catch(() => ({}))) as { error?: unknown };
      return body.error === 'already_subscribed'
        ? { error: 'Your subscription is active. Reload the page to see it.' }
        : { error: 'You already own shepetal. Reload the page to see it.' };
    }
    const body = (await res.json().catch(() => ({}))) as { url?: unknown };
    if (res.ok && typeof body.url === 'string') return { url: body.url };
  } catch {
    // network failure: same message as a server error
  }
  return { error: 'Checkout did not open. Try again in a moment.' };
}

/** POST /api/billing/portal: the Stripe Billing Portal url, or what to tell the user. */
export async function startPortal(fetchImpl: typeof fetch = fetch): Promise<{ url: string } | { error: string }> {
  try {
    const res = await fetchImpl('/api/billing/portal', { method: 'POST' });
    if (res.status === 401) return { error: 'You were signed out. Reload the page and sign in again.' };
    const body = (await res.json().catch(() => ({}))) as { url?: unknown };
    if (res.ok && typeof body.url === 'string') return { url: body.url };
  } catch {
    // network failure: same message as a server error
  }
  return { error: 'The subscription page did not open. Try again in a moment.' };
}

export const PRICE_LABEL: Record<CheckoutPlan, string> = { lifetime: '$23.99 once', monthly: '$0.99 a month' };

/** A button that opens a Stripe page: `go` returns its url or the line to show. */
function StripeButton({ label, busyLabel, quiet, go }: { label: string; busyLabel: string; quiet: boolean; go: () => ReturnType<typeof startPortal> }) {
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
          const r = await go();
          if ('url' in r) return window.location.assign(r.url);
          setError(r.error);
          setBusy(false);
        }}
      >
        {busy ? busyLabel : label}
      </button>
      {error && (
        <p role="alert" className="mt-3 text-sm text-[var(--rec)]">
          {error}
        </p>
      )}
    </div>
  );
}

export function BuyButton({ plan = 'lifetime', quiet = false }: { plan?: CheckoutPlan; quiet?: boolean }) {
  return <StripeButton label={PRICE_LABEL[plan]} busyLabel="Opening checkout…" quiet={quiet} go={() => startCheckout(plan)} />;
}

/** Subscribers: cancel, resume or change the card in the Stripe Billing Portal. */
export function ManageButton({ quiet = true }: { quiet?: boolean }) {
  return <StripeButton label="Manage subscription" busyLabel="Opening…" quiet={quiet} go={() => startPortal()} />;
}

/**
 * The plan choice (/account#plans, where the apps' Buy button lands): $23.99 once or $0.99 a month.
 * A Product Hunt code goes in on the Stripe page and takes the one-time price to $4.99.
 */
export function PlanPicker({ quiet = false }: { quiet?: boolean }) {
  return (
    <div id="plans" className="grid w-full gap-3 sm:grid-cols-2">
      <div className="rounded-xl border border-[var(--line)] p-5">
        <p className="font-semibold">Yours forever.</p>
        <p className="mb-4 mt-1 text-sm text-[var(--hush)]">One payment. Updates included.</p>
        <BuyButton plan="lifetime" quiet={quiet} />
      </div>
      <div className="rounded-xl border border-[var(--line)] p-5">
        <p className="font-semibold">Month to month.</p>
        <p className="mb-4 mt-1 text-sm text-[var(--hush)]">Cancel anytime.</p>
        <BuyButton plan="monthly" quiet />
      </div>
    </div>
  );
}
