'use client';

import { useState } from 'react';

export type CheckoutPlan = 'lifetime' | 'monthly';

const CODE_ERRORS: Record<string, string> = {
  invalid_code: 'This code is not valid.',
  code_not_applicable: 'This code has ended, or this account has used it.',
  code_lifetime_only: 'The code works on the one-time price.',
};

/**
 * POST /api/checkout (API.md) with the web session, the plan and an optional code (lifetime only). The url to open,
 * or what to tell the user.
 */
export async function startCheckout(
  plan: CheckoutPlan,
  fetchImpl: typeof fetch = fetch,
  code?: string,
): Promise<{ url: string } | { error: string }> {
  try {
    const res = await fetchImpl('/api/checkout', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(code ? { plan, code } : { plan }),
    });
    if (res.status === 401) return { error: 'You were signed out. Reload the page and sign in again.' };
    if (res.status === 400) {
      const body = (await res.json().catch(() => ({}))) as { error?: string };
      const known = body.error && CODE_ERRORS[body.error];
      if (known) return { error: known };
    }
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

export function BuyButton({ plan = 'lifetime', quiet = false, code }: { plan?: CheckoutPlan; quiet?: boolean; code?: string }) {
  return <StripeButton label={PRICE_LABEL[plan]} busyLabel="Opening checkout…" quiet={quiet} go={() => startCheckout(plan, fetch, code)} />;
}

/** The one-time price with a field for a code (PRODUCTHUNT takes it to $4.99). The code never goes with the monthly plan. */
function LifetimeWithCode({ quiet }: { quiet: boolean }) {
  const [code, setCode] = useState('');
  return (
    <div>
      <label className="mb-3 block text-sm">
        <span className="text-[var(--hush)]">Code</span>
        <input
          type="text"
          name="code"
          value={code}
          onChange={(e) => setCode(e.target.value)}
          autoComplete="off"
          spellCheck={false}
          className="mt-1 block w-full rounded-lg border border-[var(--line)] bg-transparent px-3 py-2 uppercase"
        />
      </label>
      <BuyButton plan="lifetime" quiet={quiet} code={code.trim() || undefined} />
    </div>
  );
}

/** Subscribers: cancel, resume or change the card in the Stripe Billing Portal. */
export function ManageButton({ quiet = true }: { quiet?: boolean }) {
  return <StripeButton label="Manage subscription" busyLabel="Opening…" quiet={quiet} go={() => startPortal()} />;
}

/**
 * The plan choice (/account#plans, where the apps' Buy button lands): $23.99 once or $0.99 a month.
 * A Product Hunt code goes in the lifetime card's Code field and takes the one-time price to $4.99. Stripe's own
 * code field stays off: backant.io's codes on the same Stripe account must never reach shepetal.
 */
export function PlanPicker({ quiet = false }: { quiet?: boolean }) {
  return (
    <div id="plans" className="grid w-full gap-3 sm:grid-cols-2">
      <div className="rounded-xl border border-[var(--line)] p-5">
        <p className="font-semibold">Yours forever.</p>
        <p className="mb-4 mt-1 text-sm text-[var(--hush)]">One payment. Updates included.</p>
        <LifetimeWithCode quiet={quiet} />
      </div>
      <div className="rounded-xl border border-[var(--line)] p-5">
        <p className="font-semibold">Month to month.</p>
        <p className="mb-4 mt-1 text-sm text-[var(--hush)]">Cancel anytime.</p>
        <BuyButton plan="monthly" quiet />
      </div>
    </div>
  );
}
