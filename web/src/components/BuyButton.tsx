'use client';

import { useRef, useState } from 'react';

export type CheckoutPlan = 'lifetime' | 'monthly';
type Opened = { url: string } | { error: string };
type Done = { ok: true } | { error: string };

const SIGNED_OUT = 'You were signed out. Reload the page and sign in again.';

const CODE_ERRORS: Record<string, string> = {
  invalid_code: 'This code is not valid.',
  code_lifetime_only: 'The code works on the one-time price.',
};

/**
 * POST /api/checkout (API.md) with the web session, the plan and an optional code (lifetime only). The url to open,
 * or what to tell the user.
 */
export async function startCheckout(plan: CheckoutPlan, fetchImpl: typeof fetch = fetch, code?: string): Promise<Opened> {
  try {
    const res = await fetchImpl('/api/checkout', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(code ? { plan, code } : { plan }),
    });
    if (res.status === 401) return { error: SIGNED_OUT };
    if (res.status === 400) {
      const body = (await res.json().catch(() => ({}))) as { error?: string; message?: string };
      // code_not_applicable carries its own line: "This code is for a first purchase." or "This code has ended."
      const known = body.error === 'code_not_applicable' ? body.message : body.error && CODE_ERRORS[body.error];
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

/** POST /api/billing/portal: the Stripe Billing Portal url (card, invoices), or what to tell the user. */
export async function startPortal(fetchImpl: typeof fetch = fetch): Promise<Opened> {
  try {
    const res = await fetchImpl('/api/billing/portal', { method: 'POST' });
    if (res.status === 401) return { error: SIGNED_OUT };
    const body = (await res.json().catch(() => ({}))) as { url?: unknown };
    if (res.ok && typeof body.url === 'string') return { url: body.url };
  } catch {
    // network failure: same message as a server error
  }
  return { error: 'Billing did not open. Try again in a moment.' };
}

/** POST /api/billing/cancel or /api/billing/resume (API.md): cancel at period end, or undo it before the period ends. */
export async function changeRenewal(action: 'cancel' | 'resume', fetchImpl: typeof fetch = fetch): Promise<Done> {
  try {
    const res = await fetchImpl(`/api/billing/${action}`, { method: 'POST' });
    if (res.status === 401) return { error: SIGNED_OUT };
    if (res.ok) return { ok: true };
    if (res.status === 404 || res.status === 409) return { error: 'Your subscription changed. Reload the page to see it.' };
  } catch {
    // network failure: same message as a server error
  }
  return {
    error:
      action === 'cancel'
        ? 'Your subscription is still on. Try again in a moment.'
        : 'Your subscription did not resume. Try again in a moment.',
  };
}

/** A button that runs `go` and opens the url it returns, or shows its line. */
function GoButton({
  label,
  busyLabel,
  className,
  go,
}: {
  label: string;
  busyLabel: string;
  className: string;
  go: () => Promise<Opened>;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  return (
    <div>
      <button
        type="button"
        className={className}
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
        <p role="alert" className="s-alert">
          {error}
        </p>
      )}
    </div>
  );
}

/** A Stripe Checkout for one plan; a code goes only with the lifetime plan. */
export function BuyButton({
  plan,
  label,
  className = 's-btn',
  code,
}: {
  plan: CheckoutPlan;
  label: string;
  className?: string;
  code?: string;
}) {
  return (
    <GoButton label={label} busyLabel="Opening checkout…" className={className} go={() => startCheckout(plan, fetch, code)} />
  );
}

/** The one-time price with a field for a code (PRODUCTHUNT takes it to $4.99). The code never goes with the monthly plan. */
function LifetimeWithCode() {
  const [code, setCode] = useState('');
  return (
    <div className="s-plan-buy">
      <label className="s-field">
        <span className="s-label">Code</span>
        <input
          type="text"
          name="code"
          value={code}
          onChange={(e) => setCode(e.target.value)}
          autoComplete="off"
          spellCheck={false}
          className="s-input"
        />
      </label>
      <BuyButton plan="lifetime" label="Buy once" code={code.trim() || undefined} />
    </div>
  );
}

/**
 * The two plans side by side, as on the landing page: $23.99 once, or $0.99 a month. The apps' Buy button lands here
 * (/account#plans). A Product Hunt code goes in the lifetime card's Code field and takes the one-time price to $4.99.
 * Stripe's own code field stays off: backant.io's codes on the same Stripe account must never reach shepetal.
 */
export function PlanPicker() {
  return (
    <div id="plans" className="s-plans">
      <div className="s-plan">
        <p className="s-price">$23.99</p>
        <p className="s-price-line">once. Yours forever.</p>
        <LifetimeWithCode />
      </div>
      <div className="s-plan">
        <p className="s-price">$0.99</p>
        <p className="s-price-line">a month.</p>
        <BuyButton plan="monthly" label="Subscribe" className="s-btn s-btn-line" />
      </div>
    </div>
  );
}

/** Switch to lifetime: a checkout for the $23.99 price. Once paid, the subscription ends with no further charge. */
export function SwitchToLifetime() {
  return <BuyButton plan="lifetime" label="Switch to lifetime" className="s-btn" />;
}

/**
 * Cancel subscription, with a confirmation. It cancels at the end of the period: nothing is charged again, and the
 * license works until `until`.
 */
export function CancelSubscription({ until }: { until: string }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  return (
    <>
      <button type="button" className="s-btn s-btn-line" onClick={() => dialog.current?.showModal()}>
        Cancel subscription
      </button>
      <dialog ref={dialog} className="s-dialog" aria-labelledby="cancel-title" onClose={() => setError('')}>
        <h2 id="cancel-title">Cancel your subscription?</h2>
        <p>It ends on {until}. shepetal works until then, and nothing is charged again.</p>
        <div className="s-actions">
          <button
            type="button"
            className="s-btn"
            disabled={busy}
            onClick={async () => {
              setBusy(true);
              setError('');
              const r = await changeRenewal('cancel');
              if ('ok' in r) return window.location.assign(window.location.pathname);
              setError(r.error);
              setBusy(false);
            }}
          >
            {busy ? 'Cancelling…' : 'Cancel subscription'}
          </button>
          <button type="button" className="s-btn s-btn-line" autoFocus onClick={() => dialog.current?.close()}>
            Keep it
          </button>
        </div>
        {error && (
          <p role="alert" className="s-alert">
            {error}
          </p>
        )}
      </dialog>
    </>
  );
}

/** Resume: undo the cancel before the period ends, so it renews again. */
export function ResumeSubscription() {
  return (
    <GoButton
      label="Resume subscription"
      busyLabel="Resuming…"
      className="s-btn s-btn-line"
      go={async () => {
        const r = await changeRenewal('resume');
        return 'ok' in r ? { url: window.location.pathname } : r;
      }}
    />
  );
}
