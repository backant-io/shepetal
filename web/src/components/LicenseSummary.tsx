import type { License } from '@/lib/account';

const DAY_MS = 86_400_000;

/** Whole days left, rounded up: 30 right after sign-in, 1 on the last day, never 0 while the trial runs. */
export function daysLeft(trialEndsAt: string, now = Date.now()): number {
  return Math.max(0, Math.ceil((Date.parse(trialEndsAt) - now) / DAY_MS));
}

const dateFmt = new Intl.DateTimeFormat('en-US', { month: 'long', day: 'numeric', year: 'numeric', timeZone: 'UTC' });
/** A date as the account page writes it: November 20, 2026. */
export const day = (iso: string | null | undefined) => (iso ? dateFmt.format(new Date(iso)) : '');
const days = (n: number) => `${n} ${n === 1 ? 'day' : 'days'} left.`;

/** The headline of /account and the line under it: the plan, its next date, or what to do next. */
export function summaryOf(license: License, now = Date.now(), amount?: string | null): { title: string; line: string } {
  if (license.plan === 'lifetime') return { title: 'Yours forever.', line: 'Updates included.' };
  if (license.plan === 'subscription') {
    const through = day(license.paid_through);
    if (license.payment_failed)
      return { title: 'Payment failed.', line: 'Update your card in Manage billing to keep shepetal.' };
    if (license.status === 'active') {
      return license.renews
        ? { title: `${amount ?? '$0.99'} a month.`, line: `Renews on ${through}.` }
        : { title: `Yours until ${through}.`, line: 'Your subscription ends that day.' };
    }
    if (license.status === 'trial') {
      return {
        title: days(daysLeft(license.trial_ends_at ?? '', now)),
        line: `Your free trial runs until ${day(license.trial_ends_at)}.`,
      };
    }
    return { title: 'Your subscription ended.', line: `It ended on ${through}. Pick a plan to keep shepetal.` };
  }
  if (license.status === 'expired') {
    return {
      title: 'Your trial ended.',
      line: `It ended on ${day(license.trial_ends_at)}. Pick a plan to keep shepetal.`,
    };
  }
  return {
    title: days(daysLeft(license.trial_ends_at ?? '', now)),
    line: `Your free trial runs until ${day(license.trial_ends_at)}.`,
  };
}

/** The headline of /account. */
export function LicenseSummary({
  license,
  now = Date.now(),
  amount,
}: {
  license: License;
  now?: number;
  amount?: string | null;
}) {
  const { title, line } = summaryOf(license, now, amount);
  return (
    <>
      <h1 className="s-h1">{title}</h1>
      <p className="s-lede">{line}</p>
    </>
  );
}
