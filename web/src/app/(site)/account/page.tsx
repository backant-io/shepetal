import type { Metadata } from 'next';
import { Account } from '@/components/account/Account';
import { SiteHeader } from '@/components/site/Shell';

export const metadata: Metadata = { title: 'Your account', robots: { index: false } };

/** Sign out: a plain form (lib/auth.ts signOutPost), then the landing page. */
function SignOut() {
  return (
    <form className="s-form" method="post" action="/api/auth/signout">
      <button type="submit" className="s-textbtn s-mono s-ink">
        Sign out
      </button>
    </form>
  );
}

/**
 * /account, static: the email, the trial or plan, the download and the plan settings, filled in by the browser from
 * GET /api/account. worker.ts sends a signed-out visit to the sign-in page first.
 */
export default function AccountPage() {
  return (
    <>
      <SiteHeader end={<SignOut />} />
      <Account />
    </>
  );
}
