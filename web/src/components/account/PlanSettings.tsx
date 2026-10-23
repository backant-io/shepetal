import type { PlanSettings as Settings } from '@/lib/account';
import { CancelSubscription, PlanPicker, ResumeSubscription, SwitchToLifetime } from '@/components/BuyButton';
import { day } from '@/components/LicenseSummary';

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="s-row">
      <span className="s-mono">{label}</span>
      <div>{children}</div>
    </div>
  );
}

function Value({ children, note }: { children: React.ReactNode; note?: React.ReactNode }) {
  return (
    <div className="s-val">
      {children}
      {note && <span className="s-val-note">{note}</span>}
    </div>
  );
}

/** What the Plan row says for each plan. */
export function planLine(s: Settings): { value: string; note: string } {
  if (s.plan === 'lifetime') return { value: 'Lifetime', note: 'Yours forever.' };
  if (s.plan === 'subscription' && s.subscription && s.subscription.status !== 'ended') {
    return { value: 'Monthly', note: `${s.subscription.amount_display ?? '$0.99'} a month.` };
  }
  if (s.trial)
    return { value: 'Free trial', note: `${s.trial.days_left} ${s.trial.days_left === 1 ? 'day' : 'days'} left.` };
  if (s.subscription?.status === 'ended')
    return { value: 'Subscription ended', note: `Ended on ${day(s.subscription.ends_at)}.` };
  return { value: 'Free trial', note: 'Ended.' };
}

/** Cancelled to a date after the paid time: one more charge comes, shortened to that date. */
export const lastCharge = (sub: NonNullable<Settings['subscription']>) =>
  sub.status === 'cancels_at_period_end' && !!sub.paid_through && !!sub.ends_at && Date.parse(sub.ends_at) > Date.parse(sub.paid_through);

/** What the Status row says for a subscription. */
export function statusLine(sub: NonNullable<Settings['subscription']>): { value: string; note: string } {
  switch (sub.status) {
    case 'active':
      return { value: 'Active', note: `Renews on ${day(sub.next_billing_date)}.` };
    case 'cancels_at_period_end':
      return { value: lastCharge(sub) ? 'Cancelled' : 'Cancels at the end of the period', note: `Works until ${day(sub.ends_at)}.` };
    case 'past_due':
      return { value: 'Payment failed', note: 'Update your card in Manage billing.' };
    default:
      return { value: 'Ended', note: `Ended on ${day(sub.ends_at)}.` };
  }
}

/**
 * The plan settings on /account (GET /api/account/plan's shape): the plan, and for a subscriber the status, the next
 * charge, Manage billing, Switch to lifetime and Cancel subscription. Lifetime owners get "Yours forever." and no
 * subscription controls; trial users get the two plans side by side, as on the landing page.
 */
export function PlanSettings({ settings }: { settings: Settings }) {
  const plan = planLine(settings);
  const sub = settings.subscription && settings.subscription.status !== 'ended' ? settings.subscription : null;
  const { actions } = settings;
  return (
    <section aria-labelledby="settings-title" className="s-settings">
      <h2 id="settings-title" className="s-mono s-section-label">
        Settings
      </h2>
      <div className="s-rows">
        <Row label="Email">
          <Value>{settings.email}</Value>
        </Row>
        <Row label="Plan">
          <Value note={plan.note}>{plan.value}</Value>
        </Row>
        {sub && (
          <Row label="Status">
            <Value note={statusLine(sub).note}>{statusLine(sub).value}</Value>
          </Row>
        )}
        {sub && (
          <Row label="Next charge">
            {sub.status === 'active' && sub.next_billing_date ? (
              <Value note={`On ${day(sub.next_billing_date)}.`}>{sub.amount_display ?? '$0.99'}</Value>
            ) : lastCharge(sub) ? (
              // An end on a date after the paid month (/cancel): Stripe renews once more and prorates that last month.
              <Value note={`On ${day(sub.paid_through)}, only for the days up to ${day(sub.ends_at)}. Nothing after that.`}>
                One last charge
              </Value>
            ) : (
              <Value note={sub.status === 'past_due' ? 'Once the card works.' : 'Nothing is charged again.'}>
                None
              </Value>
            )}
          </Row>
        )}
        {actions.portal && settings.plan !== 'lifetime' && (
          <Row label="Billing">
            <Value note="Your card and invoices.">
              {/* A plain link: GET /api/billing/portal answers with a redirect to the Stripe Billing Portal. */}
              <a className="s-btn s-btn-line" href="/api/billing/portal">
                Manage billing
              </a>
            </Value>
          </Row>
        )}
        {actions.switch_to_lifetime && (
          <Row label="Lifetime">
            <Value note="$23.99 once. Yours forever. The subscription ends, with no further charge.">
              <span className="s-row-actions">
                <SwitchToLifetime />
              </span>
            </Value>
          </Row>
        )}
        {sub && (actions.cancel || actions.resume) && (
          <Row label="Renewal">
            {actions.cancel ? (
              <Value note="It ends at the end of the period. shepetal works until then.">
                <span className="s-row-actions">
                  <CancelSubscription until={day(sub.paid_through)} />
                </span>
              </Value>
            ) : (
              <Value note={`Cancelled. It ends on ${day(sub.ends_at)}.`}>
                <span className="s-row-actions">
                  <ResumeSubscription />
                </span>
              </Value>
            )}
          </Row>
        )}
      </div>
      {actions.choose_plan && <PlanPicker />}
    </section>
  );
}
