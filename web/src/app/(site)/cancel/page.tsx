import type { Metadata } from 'next';
import { SiteHeader } from '@/components/site/Shell';
import { ASAP, CONTRACT, DATE_RULE, KIND } from '@/lib/cancel';

export const metadata: Metadata = {
  title: 'Cancel your contract',
  description: 'Cancel your shepetal subscription without signing in.',
  alternates: { canonical: '/cancel' },
};

/**
 * Where "Verträge hier kündigen" in the footer leads (§ 312k BGB): no sign-in, and nothing on the page but what the
 * law lists (the type of cancellation and a reason, who you are, the contract, when it ends, where the confirmation
 * goes: the email field is both, § 312k(2) Nr. 1 b and e) and the "Jetzt kündigen" button. No offers, no "are you sure?" (BGH I ZR 200/25). Static: a plain form that
 * works without JavaScript, posted to /api/cancel, which worker.ts answers.
 */
export default function Cancel() {
  return (
    <>
      <SiteHeader />
      <main className="s-main s-legal">
        <h1 className="s-h2">Cancel your contract</h1>
        <form className="s-cancel" method="post" action="/api/cancel">
          <fieldset>
            <legend>Type of cancellation</legend>
            <label>
              <input type="radio" name="kind" value="ordinary" defaultChecked /> {KIND.ordinary}
            </label>
            <label>
              <input type="radio" name="kind" value="extraordinary" /> {KIND.extraordinary}
            </label>
            <label className="s-cancel-field">
              Reason, for an extraordinary cancellation
              <textarea name="reason" rows={3} maxLength={2000} />
            </label>
          </fieldset>
          <fieldset>
            <legend>Contract</legend>
            <label>
              <input type="radio" name="contract" value="monthly" defaultChecked /> {CONTRACT.monthly}
            </label>
            <label>
              <input type="radio" name="contract" value="lifetime" /> {CONTRACT.lifetime}
            </label>
          </fieldset>
          <fieldset>
            <legend>End of the contract</legend>
            <label>
              <input type="radio" name="end" value="asap" defaultChecked /> {ASAP}
            </label>
            <label>
              <input type="radio" name="end" value="date" /> On this date, {DATE_RULE}:
            </label>
            <label className="s-cancel-field">
              Date
              <input type="date" name="date" />
            </label>
          </fieldset>
          <label className="s-cancel-field">
            Email of your shepetal account: it identifies your contract, and the confirmation goes to it
            <input type="email" name="email" required autoComplete="email" maxLength={254} />
          </label>
          <button type="submit" className="s-btn s-btn-signal">
            Jetzt kündigen
          </button>
        </form>
      </main>
    </>
  );
}
