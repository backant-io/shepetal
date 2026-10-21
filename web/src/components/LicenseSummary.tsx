import type { License } from '@/lib/account';

const DAY_MS = 86_400_000;

/** Whole days left, rounded up: 30 right after sign-in, 1 on the last day, never 0 while the trial runs. */
export function daysLeft(trialEndsAt: string, now = Date.now()): number {
  return Math.max(0, Math.ceil((Date.parse(trialEndsAt) - now) / DAY_MS));
}

const dateFmt = new Intl.DateTimeFormat('en-US', { month: 'long', day: 'numeric', year: 'numeric', timeZone: 'UTC' });

/** The headline of /account: trial days left, "yours forever", or an ended trial. */
export function LicenseSummary({ license, now = Date.now() }: { license: License; now?: number }) {
  if (license.status === 'active') {
    return (
      <>
        <p className="display text-[clamp(3rem,10vw,5rem)] leading-none">Yours forever.</p>
        <p className="mt-4 text-[var(--hush)]">You bought shepetal. Future updates are included.</p>
      </>
    );
  }
  const ends = license.trial_ends_at ? dateFmt.format(new Date(license.trial_ends_at)) : '';
  if (license.status === 'expired') {
    return (
      <>
        <p className="display text-[clamp(3rem,10vw,5rem)] leading-none">Your trial ended.</p>
        <p className="mt-4 text-[var(--hush)]">
          It ended on {ends}. Buy shepetal once for $4.99 to keep using it, with future updates included.
        </p>
      </>
    );
  }
  const n = daysLeft(license.trial_ends_at ?? '', now);
  return (
    <>
      <p className="display text-[clamp(3rem,10vw,5rem)] leading-none">
        {n} {n === 1 ? 'day' : 'days'} left
      </p>
      <p className="mt-4 text-[var(--hush)]">
        Your free trial runs until {ends}. After that it is $4.99 once, and shepetal is yours forever.
      </p>
    </>
  );
}
