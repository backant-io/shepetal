import type { Metadata } from 'next';
import { PlanSettings } from '@/components/account/PlanSettings';
import { LicenseSummary } from '@/components/LicenseSummary';
import { SiteHeader } from '@/components/site/Shell';
import { SignIn } from '@/components/site/SignIn';
import { licenseOf, planSettings, upsertUser } from '@/lib/account';
import { auth, signOut } from '@/lib/auth';

export const metadata: Metadata = { title: 'Your account', robots: { index: false } };

type Query = { purchased?: string; cancelled?: string; portal?: string };

/** The line on top after a round trip to Stripe. */
function notice(q: Query, active: boolean, lifetime: boolean): string | null {
  if (q.purchased) {
    if (!active) return 'Thank you. Your payment can take a minute to show up here, so reload the page in a moment.';
    return lifetime ? 'Yours forever, updates included. Thank you.' : 'Your subscription is on. Thank you.';
  }
  if (q.cancelled) return 'Your subscription is cancelled. shepetal works until the end of the period.';
  if (q.portal === 'none') return 'Billing opens once you have bought a plan.';
  return null;
}

function SignOut() {
  return (
    <form
      className="s-form"
      action={async () => {
        'use server';
        await signOut({ redirectTo: '/' });
      }}
    >
      <button type="submit" className="s-textbtn s-mono s-ink">
        Sign out
      </button>
    </form>
  );
}

/** /account: the email, the trial or plan, the download, and the plan settings. Signed out, the sign-in page. */
export default async function AccountPage({ searchParams }: { searchParams: Promise<Query> }) {
  const email = (await auth())?.user?.email;
  if (!email) return <SignIn next="/account" />;

  const user = await upsertUser(email);
  const now = Date.now();
  const license = licenseOf(user, now);
  const settings = planSettings(user, now);
  const line = notice(await searchParams, license.status === 'active', license.plan === 'lifetime');

  return (
    <>
      <SiteHeader end={<SignOut />} />
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
              <a href="/install" className="s-btn">
                Download for Mac
              </a>
              <span className="s-mono">macOS 14.4 or later, Apple silicon</span>
            </div>
          </div>
          <PlanSettings settings={settings} />
        </div>
      </main>
    </>
  );
}
