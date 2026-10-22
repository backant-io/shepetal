'use client';

import { useEffect, useState } from 'react';
import type { License, PlanSettings as Settings } from '@/lib/account';
import { PlanSettings } from '@/components/account/PlanSettings';
import { LicenseSummary } from '@/components/LicenseSummary';

type Data = { license: License; settings: Settings };

/** The line on top after a round trip to Stripe. */
export function notice(q: URLSearchParams, active: boolean, lifetime: boolean): string | null {
  if (q.get('purchased')) {
    if (!active) return 'Thank you. Your payment can take a minute to show up here, so reload the page in a moment.';
    return lifetime ? 'Yours forever, updates included. Thank you.' : 'Your subscription is on. Thank you.';
  }
  if (q.get('cancelled')) return 'Your subscription is cancelled. shepetal works until the end of the period.';
  if (q.get('portal') === 'none') return 'Billing opens once you have bought a plan.';
  return null;
}

// Where the visitor came from (?ref=, utm_*), carried on to /install, which checks the values itself.
const ATTRIBUTION = ['ref', 'utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content'];

/** The account as the signed-in user sees it. */
export function AccountBody({ license, settings, search, now }: Data & { search: string; now: number }) {
  const q = new URLSearchParams(search);
  const line = notice(q, license.status === 'active', license.plan === 'lifetime');
  const kept = new URLSearchParams([...q].filter(([k]) => ATTRIBUTION.includes(k))).toString();
  const from = kept ? `?${kept}` : '';
  return (
    <main className="s-main">
      {line && (
        <p role="status" className="s-status">
          {line}
        </p>
      )}
      <div className="s-acct">
        <div className="s-acct-head">
          <p className="s-mono s-section-label">Account</p>
          <LicenseSummary license={license} now={now} amount={settings.subscription?.amount_display} />
          <div className="s-actions">
            {/* /install starts the download and shows how to install the app macOS cannot verify. */}
            <a href={`/install${from}`} className="s-btn">
              Download for Mac
            </a>
            <span className="s-mono">macOS 14.4 or later, Apple silicon</span>
          </div>
        </div>
        <PlanSettings settings={settings} />
      </div>
    </main>
  );
}

/** Loads GET /api/account (the session cookie); signed out, the sign-in page, which comes back here. */
export function Account() {
  const [data, setData] = useState<Data | null>(null);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    fetch('/api/account', { cache: 'no-store' })
      .then(async (r) => {
        if (r.status === 401) return location.replace(`/login?next=${encodeURIComponent(location.pathname + location.search)}`);
        if (!r.ok) throw new Error(String(r.status));
        setData(await r.json());
      })
      .catch(() => setFailed(true));
  }, []);
  if (data) return <AccountBody {...data} search={location.search} now={Date.now()} />;
  return (
    <main className="s-main">
      {failed && (
        <p role="alert" className="s-alert">
          Your account did not load. Reload the page.
        </p>
      )}
    </main>
  );
}
