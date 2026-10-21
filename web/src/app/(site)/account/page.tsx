import type { Metadata } from 'next';
import { BuyButton, ManageButton, PlanPicker } from '@/components/BuyButton';
import { actionsFor, LicenseSummary } from '@/components/LicenseSummary';
import { SignInButton } from '@/components/SignInButton';
import { getLicense } from '@/lib/account';
import { auth, signOut } from '@/lib/auth';

export const metadata: Metadata = { title: 'Your account', robots: { index: false } };

export default async function AccountPage({ searchParams }: { searchParams: Promise<{ purchased?: string }> }) {
  const email = (await auth())?.user?.email;

  if (!email) {
    return (
      <main className="mx-auto max-w-xl px-4 pt-16 sm:px-8">
        <h1 className="display text-[clamp(3rem,10vw,5rem)] leading-none">Sign in</h1>
        <p className="mt-6 text-lg leading-relaxed">
          Sign in with your Google account to start your free trial and download shepetal. The trial runs for 30 days
          and needs no credit card.
        </p>
        <div className="mt-10">
          <SignInButton redirectTo="/account" />
        </div>
      </main>
    );
  }

  const license = await getLicense(email);
  const { purchased } = await searchParams;
  const { plans, manage } = actionsFor(license);

  return (
    <main className="mx-auto max-w-xl px-4 pt-16 sm:px-8">
      <h1 className="sr-only">Your account</h1>
      {purchased && (
        <p role="status" className="mb-10 rounded-xl bg-[var(--raised)] px-4 py-3">
          {license.status !== 'active'
            ? 'Thank you. Your payment can take a minute to show up here, so reload the page in a moment.'
            : license.plan === 'lifetime'
              ? 'Yours forever, updates included. Thank you.'
              : 'Your subscription is on. Thank you.'}
        </p>
      )}
      <LicenseSummary license={license} />

      <div className="mt-10 flex flex-wrap items-start gap-3">
        {/* A plain link: /download answers with a redirect to the installer. */}
        <a href="/download" className={license.status === 'expired' ? 'btn btn-quiet' : 'btn'}>
          Download for Mac
        </a>
        {manage && <ManageButton quiet={!license.payment_failed} />}
        {/* A subscriber can still buy it once: the subscription then stops renewing. */}
        {manage && license.status === 'active' && <BuyButton plan="lifetime" quiet />}
      </div>
      {plans && (
        <div className="mt-6">
          <PlanPicker quiet={license.status === 'trial'} />
        </div>
      )}
      <p className="mt-4 text-sm text-[var(--hush)]">Needs macOS 14.4 or later and a Mac with Apple silicon.</p>

      <div className="mt-16 flex flex-wrap items-center justify-between gap-4 border-t border-[var(--line)] pt-6 text-sm">
        <p>
          Signed in as <span className="font-semibold">{license.email}</span>
        </p>
        <form
          action={async () => {
            'use server';
            await signOut({ redirectTo: '/' });
          }}
        >
          <button type="submit" className="text-[var(--hush)] underline underline-offset-4 hover:text-[var(--ink)]">
            Sign out
          </button>
        </form>
      </div>
    </main>
  );
}
