import type { License } from '@/lib/account';

const DAY_MS = 86_400_000;

/** Whole days left, rounded up: 30 right after sign-in, 1 on the last day, never 0 while the trial runs. */
export function daysLeft(trialEndsAt: string, now = Date.now()): number {
  return Math.max(0, Math.ceil((Date.parse(trialEndsAt) - now) / DAY_MS));
}

const dateFmt = new Intl.DateTimeFormat('en-US', { month: 'long', day: 'numeric', year: 'numeric', timeZone: 'UTC' });
const day = (iso: string | null) => (iso ? dateFmt.format(new Date(iso)) : '');

function Summary({ title, line }: { title: string; line: string }) {
  return (
    <>
      <p className="display text-[clamp(3rem,10vw,5rem)] leading-none">{title}</p>
      <p className="mt-4 text-[var(--hush)]">{line}</p>
    </>
  );
}

/** What /account offers under the summary: the plan choice, the Billing Portal, or nothing. */
export function actionsFor(license: License): { plans: boolean; manage: boolean } {
  if (license.plan === 'lifetime') return { plans: false, manage: false };
  if (license.plan === 'subscription') {
    const live = license.status === 'active' || license.payment_failed;
    return { plans: !live, manage: live };
  }
  return { plans: true, manage: false };
}

/** The headline of /account: the plan, its next date, or what to do next. */
export function LicenseSummary({ license, now = Date.now() }: { license: License; now?: number }) {
  if (license.plan === 'lifetime') return <Summary title="Yours forever." line="Updates included." />;
  if (license.plan === 'subscription') {
    const through = day(license.paid_through);
    if (license.payment_failed) {
      return <Summary title="Payment failed." line="Update your card in Manage subscription to keep shepetal." />;
    }
    if (license.status === 'active') {
      return license.renews ? (
        <Summary title="$0.99 a month." line={`Renews on ${through}. Cancel anytime.`} />
      ) : (
        <Summary title={`Yours until ${through}.`} line="Your subscription ends that day. Resume it in Manage subscription." />
      );
    }
    if (license.status === 'trial') {
      const n = daysLeft(license.trial_ends_at ?? '', now);
      return <Summary title={`${n} ${n === 1 ? 'day' : 'days'} left`} line={`Your subscription ended. Your free trial runs until ${day(license.trial_ends_at)}.`} />;
    }
    return <Summary title="Your subscription ended." line={`It ended on ${through}. Pick a plan to keep shepetal.`} />;
  }
  if (license.status === 'expired') {
    return <Summary title="Your trial ended." line={`It ended on ${day(license.trial_ends_at)}. Pick a plan to keep shepetal.`} />;
  }
  const n = daysLeft(license.trial_ends_at ?? '', now);
  return (
    <Summary
      title={`${n} ${n === 1 ? 'day' : 'days'} left`}
      line={`Your free trial runs until ${day(license.trial_ends_at)}. Then $23.99 once, or $0.99 a month.`}
    />
  );
}
