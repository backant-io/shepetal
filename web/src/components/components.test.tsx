import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it, vi } from 'vitest';
import type { License, PlanSettings as Settings } from '@/lib/account';
import { planLine, PlanSettings, statusLine } from './account/PlanSettings';
import { changeRenewal, PlanPicker, startCheckout, startPortal } from './BuyButton';
import { daysLeft, LicenseSummary, summaryOf } from './LicenseSummary';

const json = (status: number, body: unknown) =>
  vi.fn<typeof fetch>(async () => new Response(JSON.stringify(body), { status }));

describe('Buy button', () => {
  it('posts the plan to /api/checkout and opens the Stripe url it returns', async () => {
    for (const plan of ['lifetime', 'monthly'] as const) {
      const f = json(200, { url: 'https://checkout.stripe.com/c/pay/cs_test_1' });
      expect(await startCheckout(plan, f)).toEqual({ url: 'https://checkout.stripe.com/c/pay/cs_test_1' });
      expect(f).toHaveBeenCalledWith('/api/checkout', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ plan }),
      });
    }
  });

  it('tells a signed-out user to sign in again, and an owner or subscriber what they have, so nobody pays twice', async () => {
    expect(await startCheckout('lifetime', json(401, { error: 'unauthorized' }))).toEqual({
      error: expect.stringMatching(/sign in again/),
    });
    expect(await startCheckout('lifetime', json(409, { error: 'already_active' }))).toEqual({
      error: expect.stringMatching(/already own/),
    });
    expect(await startCheckout('monthly', json(409, { error: 'already_subscribed' }))).toEqual({
      error: expect.stringMatching(/subscription is active/),
    });
  });

  it('sends a code with the lifetime plan, and says why a code was refused', async () => {
    const f = json(200, { url: 'https://checkout.stripe.com/c/pay/cs_test_2' });
    await startCheckout('lifetime', f, 'PRODUCTHUNT');
    expect(f).toHaveBeenCalledWith('/api/checkout', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ plan: 'lifetime', code: 'PRODUCTHUNT' }) });
    expect(await startCheckout('lifetime', json(400, { error: 'invalid_code' }), 'NOPE')).toEqual({ error: 'This code is not valid.' });
    expect(await startCheckout('lifetime', json(400, { error: 'code_not_applicable', message: 'This code is for a first purchase.' }), 'PRODUCTHUNT')).toEqual({ error: 'This code is for a first purchase.' });
  });

  it('never navigates on a server error, a missing url or a network failure', async () => {
    for (const f of [
      json(500, { url: 'https://checkout.stripe.com/x' }),
      json(200, {}),
      vi.fn<typeof fetch>(async () => Promise.reject(new Error('offline'))),
    ]) {
      expect(await startCheckout('lifetime', f)).toEqual({ error: expect.stringMatching(/did not open/) });
      expect(await startPortal(f)).toEqual({ error: expect.stringMatching(/did not open/) });
    }
  });

  it('opens the Billing Portal for the card and invoices', async () => {
    const f = json(200, { url: 'https://billing.stripe.com/p/session/1' });
    expect(await startPortal(f)).toEqual({ url: 'https://billing.stripe.com/p/session/1' });
    expect(f).toHaveBeenCalledWith('/api/billing/portal', { method: 'POST' });
  });

  it('cancels at period end and resumes through the billing API, and says when it did not', async () => {
    for (const action of ['cancel', 'resume'] as const) {
      const f = json(200, { plan: 'subscription' });
      expect(await changeRenewal(action, f)).toEqual({ ok: true });
      expect(f).toHaveBeenCalledWith(`/api/billing/${action}`, { method: 'POST' });
      expect(await changeRenewal(action, json(401, {}))).toEqual({ error: expect.stringMatching(/sign in again/) });
      expect(await changeRenewal(action, json(404, { error: 'no_subscription' }))).toEqual({
        error: expect.stringMatching(/Reload/),
      });
    }
    expect(await changeRenewal('cancel', json(500, {}))).toEqual({ error: expect.stringMatching(/still on/) });
  });

  it('offers both plans side by side, as on the landing page, and never the retired price', () => {
    const html = renderToStaticMarkup(<PlanPicker />);
    expect(html).toContain('id="plans"');
    expect(html).toMatch(/\$23\.99<\/p><p class="s-price-line">once\. Yours forever\.<\/p>/);
    expect(html).toMatch(/\$0\.99<\/p><p class="s-price-line">a month\.<\/p>/);
    expect(html).toContain('Buy once');
    expect(html).toContain('Subscribe');
    expect(html).toContain('name="code"');
    expect(html).not.toContain('4.99');
  });
});

describe('/account headline', () => {
  const DAY = 86_400_000;
  const now = Date.parse('2026-10-20T12:00:00.000Z');
  const email = 'a@example.com';
  const base: License = {
    status: 'trial',
    plan: 'trial',
    trial_ends_at: null,
    paid_through: null,
    renews: false,
    payment_failed: false,
    email,
  };
  const of = (l: Partial<License>) => summaryOf({ ...base, ...l }, now);

  it('counts trial days up, so a fresh trial shows 30 and the last hours still show 1', () => {
    expect(daysLeft(new Date(now + 30 * DAY).toISOString(), now)).toBe(30);
    expect(daysLeft(new Date(now + 2 * 3_600_000).toISOString(), now)).toBe(1);
    expect(daysLeft(new Date(now - DAY).toISOString(), now)).toBe(0);
  });

  it('shows the days left during the trial and when it ends', () => {
    expect(of({ trial_ends_at: new Date(now + 12.5 * DAY).toISOString() })).toEqual({
      title: '13 days left.',
      line: 'Your free trial runs until November 2, 2026.',
    });
    expect(of({ trial_ends_at: new Date(now + 2 * 3_600_000).toISOString() }).title).toBe('1 day left.');
  });

  it('shows "Yours forever." for the lifetime license', () => {
    expect(of({ status: 'active', plan: 'lifetime' })).toEqual({ title: 'Yours forever.', line: 'Updates included.' });
  });

  it('shows the renewal date of a subscription, and the end date once cancelled', () => {
    const sub = { status: 'active' as const, plan: 'subscription' as const, paid_through: '2026-11-20T00:00:00.000Z' };
    expect(of({ ...sub, renews: true })).toEqual({ title: '$0.99 a month.', line: 'Renews on November 20, 2026.' });
    expect(of({ ...sub, renews: false }).title).toBe('Yours until November 20, 2026.');
  });

  it('asks for a new card after a failed renewal, and offers the plans once a trial or subscription ended', () => {
    expect(
      of({
        status: 'expired',
        plan: 'subscription',
        paid_through: '2026-10-19T00:00:00.000Z',
        renews: true,
        payment_failed: true,
      }).title,
    ).toBe('Payment failed.');
    expect(of({ status: 'expired', plan: 'subscription', paid_through: '2026-10-01T00:00:00.000Z' }).title).toBe(
      'Your subscription ended.',
    );
    expect(of({ status: 'expired', trial_ends_at: '2026-10-01T00:00:00.000Z' })).toEqual({
      title: 'Your trial ended.',
      line: 'It ended on October 1, 2026. Pick a plan to keep shepetal.',
    });
  });

  it('renders the headline as the page heading', () => {
    const html = renderToStaticMarkup(
      <LicenseSummary license={{ ...base, status: 'active', plan: 'lifetime' }} now={now} />,
    );
    expect(html).toContain('<h1 class="s-h1">Yours forever.</h1>');
  });
});

describe('/account plan settings', () => {
  const none = { cancel: false, resume: false, switch_to_lifetime: false, portal: false, choose_plan: false };
  const base: Settings = {
    plan: 'trial',
    status: 'trial',
    email: 'a@example.com',
    trial: { ends_at: '2026-11-20T12:00:00.000Z', days_left: 29 },
    lifetime: null,
    subscription: null,
    actions: { ...none, choose_plan: true },
  };
  const sub = (
    status: NonNullable<Settings['subscription']>['status'],
    actions: Partial<Settings['actions']>,
  ): Settings => ({
    ...base,
    plan: 'subscription',
    status: status === 'ended' || status === 'past_due' ? 'expired' : 'active',
    trial: null,
    subscription: {
      status,
      paid_through: '2026-11-21T09:00:00.000Z',
      next_billing_date: status === 'active' ? '2026-11-21T09:00:00.000Z' : null,
      ends_at: status === 'cancels_at_period_end' || status === 'ended' ? '2026-11-21T09:00:00.000Z' : null,
      amount: 99,
      currency: 'usd',
      amount_display: '$0.99',
      interval: 'month',
    },
    actions: { ...none, ...actions },
  });
  const render = (s: Settings) => renderToStaticMarkup(<PlanSettings settings={s} />);

  it('shows a trial user the email, the days left and the two plans, and no subscription controls', () => {
    const html = render(base);
    expect(html).toContain('a@example.com');
    expect(planLine(base)).toEqual({ value: 'Free trial', note: '29 days left.' });
    expect(html).toContain('id="plans"');
    for (const control of ['Cancel subscription', 'Switch to lifetime', 'Manage billing', 'Next charge'])
      expect(html).not.toContain(control);
  });

  it('shows a lifetime owner "Yours forever." with no subscription controls and no plans', () => {
    const life: Settings = {
      ...base,
      plan: 'lifetime',
      status: 'active',
      trial: null,
      lifetime: { purchased_at: '2026-10-21T00:00:00.000Z' },
      actions: { ...none, portal: true },
    };
    const html = render(life);
    expect(html).toContain('Lifetime');
    expect(html).toContain('Yours forever.');
    for (const control of ['Cancel subscription', 'Switch to lifetime', 'Manage billing', 'Next charge', 'id="plans"'])
      expect(html).not.toContain(control);
  });

  it('shows an active subscriber the status, the next charge and date, Manage billing, Switch to lifetime and Cancel', () => {
    const s = sub('active', { cancel: true, switch_to_lifetime: true, portal: true });
    const html = render(s);
    expect(statusLine(s.subscription!)).toEqual({ value: 'Active', note: 'Renews on November 21, 2026.' });
    expect(html).toContain('Renews on November 21, 2026.');
    expect(html).toMatch(/\$0\.99<span class="s-val-note">On November 21, 2026\.<\/span>/);
    expect(html).toContain('href="/api/billing/portal"');
    expect(html).toContain('Switch to lifetime');
    expect(html).toContain('Cancel subscription');
    // The confirmation says the date and that nothing is charged again.
    expect(html).toContain('Cancel your subscription?');
    expect(html).toContain('It ends on November 21, 2026. shepetal works until then, and nothing is charged again.');
    expect(html).not.toContain('id="plans"');
  });

  it('shows a cancelled subscription working until the period ends, with Resume instead of Cancel', () => {
    const html = render(sub('cancels_at_period_end', { resume: true, switch_to_lifetime: true, portal: true }));
    expect(html).toContain('Cancels at the end of the period');
    expect(html).toContain('Works until November 21, 2026.');
    expect(html).toContain('Nothing is charged again.');
    expect(html).toContain('Resume subscription');
    expect(html).not.toContain('Cancel subscription');
  });

  // A date after the paid month, set on /cancel: Stripe renews once more and bills the days up to it. "Nothing is
  // charged again" would be false there.
  it('shows the one last, shortened charge of a subscription cancelled to a later date', () => {
    const s = sub('cancels_at_period_end', { resume: true, switch_to_lifetime: true, portal: true });
    s.subscription!.ends_at = '2026-12-31T23:59:59.000Z';
    const html = render(s);
    expect(statusLine(s.subscription!)).toEqual({ value: 'Cancelled', note: 'Works until December 31, 2026.' });
    expect(html).toMatch(/One last charge<span class="s-val-note">On November 21, 2026, only for the days up to December 31, 2026\. Nothing after that\.<\/span>/);
    expect(html).not.toContain('Nothing is charged again.');
    expect(html).not.toContain('Cancels at the end of the period');
  });

  it('sends a subscriber whose renewal failed to Manage billing', () => {
    const html = render(sub('past_due', { cancel: true, switch_to_lifetime: true, portal: true }));
    expect(html).toContain('Payment failed');
    expect(html).toContain('Update your card in Manage billing.');
    expect(html).toContain('Manage billing');
  });

  it('offers the two plans again once a subscription ended', () => {
    const s = sub('ended', { choose_plan: true, portal: true });
    const html = render(s);
    expect(planLine(s)).toEqual({ value: 'Subscription ended', note: 'Ended on November 21, 2026.' });
    expect(html).toContain('id="plans"');
    expect(html).not.toContain('Cancel subscription');
  });
});
