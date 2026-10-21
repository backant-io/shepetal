import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it, vi } from 'vitest';
import type { License } from '@/lib/account';
import { PlanPicker, startCheckout, startPortal } from './BuyButton';
import { gesture } from './HeroDemo';
import { actionsFor, daysLeft, LicenseSummary } from './LicenseSummary';

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
    expect(await startCheckout('lifetime', json(401, { error: 'unauthorized' }))).toEqual({ error: expect.stringMatching(/sign in again/) });
    expect(await startCheckout('lifetime', json(409, { error: 'already_active' }))).toEqual({ error: expect.stringMatching(/already own/) });
    expect(await startCheckout('monthly', json(409, { error: 'already_subscribed' }))).toEqual({ error: expect.stringMatching(/subscription is active/) });
  });

  it('never navigates on a server error, a missing url or a network failure', async () => {
    for (const f of [json(500, { url: 'https://checkout.stripe.com/x' }), json(200, {}), vi.fn<typeof fetch>(async () => Promise.reject(new Error('offline')))]) {
      expect(await startCheckout('lifetime', f)).toEqual({ error: expect.stringMatching(/did not open/) });
      expect(await startPortal(f)).toEqual({ error: expect.stringMatching(/did not open/) });
    }
  });

  it('opens the Billing Portal from Manage subscription', async () => {
    const f = json(200, { url: 'https://billing.stripe.com/p/session/1' });
    expect(await startPortal(f)).toEqual({ url: 'https://billing.stripe.com/p/session/1' });
    expect(f).toHaveBeenCalledWith('/api/billing/portal', { method: 'POST' });
  });

  it('offers both plans, $23.99 once and $0.99 a month, and never the retired price', () => {
    const html = renderToStaticMarkup(<PlanPicker />);
    expect(html).toContain('id="plans"');
    expect(html).toContain('$23.99 once');
    expect(html).toContain('$0.99 a month');
    expect(html).toContain('Cancel anytime.');
    expect(html).not.toContain('4.99');
  });
});

describe('/account license summary', () => {
  const DAY = 86_400_000;
  const now = Date.parse('2026-10-20T12:00:00.000Z');
  const email = 'a@example.com';
  const base: License = { status: 'trial', plan: 'trial', trial_ends_at: null, paid_through: null, renews: false, payment_failed: false, email };
  const render = (l: Partial<License>) => renderToStaticMarkup(<LicenseSummary license={{ ...base, ...l }} now={now} />);

  it('counts trial days up, so a fresh trial shows 30 and the last hours still show 1', () => {
    expect(daysLeft(new Date(now + 30 * DAY).toISOString(), now)).toBe(30);
    expect(daysLeft(new Date(now + 2 * 3_600_000).toISOString(), now)).toBe(1);
    expect(daysLeft(new Date(now - DAY).toISOString(), now)).toBe(0);
  });

  it('shows days left during the trial, and both prices', () => {
    const html = render({ trial_ends_at: new Date(now + 12.5 * DAY).toISOString() });
    expect(html).toContain('13 days left');
    expect(html).toContain('November 2, 2026');
    expect(html).toContain('$23.99 once, or $0.99 a month');
    expect(actionsFor({ ...base })).toEqual({ plans: true, manage: false });
  });

  it('shows "yours forever" for the lifetime license, with no date and nothing to buy or manage', () => {
    const l = { ...base, status: 'active' as const, plan: 'lifetime' as const };
    const html = render(l);
    expect(html).toContain('Yours forever');
    expect(html).not.toContain('left');
    expect(actionsFor(l)).toEqual({ plans: false, manage: false });
  });

  it('shows the renewal date of a subscription, with Manage subscription', () => {
    const l = { ...base, status: 'active' as const, plan: 'subscription' as const, paid_through: '2026-11-20T00:00:00.000Z', renews: true };
    expect(render(l)).toContain('Renews on November 20, 2026');
    expect(actionsFor(l)).toEqual({ plans: false, manage: true });
  });

  it('shows when a cancelled subscription ends', () => {
    const html = render({ status: 'active', plan: 'subscription', paid_through: '2026-11-20T00:00:00.000Z', renews: false });
    expect(html).toContain('Yours until November 20, 2026');
  });

  it('asks for a new card after a failed renewal, through Manage subscription', () => {
    const l = { ...base, status: 'expired' as const, plan: 'subscription' as const, paid_through: '2026-10-19T00:00:00.000Z', renews: true, payment_failed: true };
    expect(render(l)).toContain('Payment failed');
    expect(actionsFor(l)).toEqual({ plans: false, manage: true });
  });

  it('offers the plans again once a subscription ended', () => {
    const l = { ...base, status: 'expired' as const, plan: 'subscription' as const, paid_through: '2026-10-01T00:00:00.000Z' };
    expect(render(l)).toContain('Your subscription ended');
    expect(actionsFor(l)).toEqual({ plans: true, manage: false });
  });

  it('offers the plans once the trial ended', () => {
    const html = render({ status: 'expired', trial_ends_at: '2026-10-01T00:00:00.000Z' });
    expect(html).toContain('Your trial ended');
    expect(html).toContain('Pick a plan');
    expect(html).not.toContain('4.99');
  });
});

describe('Hero demo fn gesture', () => {
  // The demo must teach the gesture the Mac app really has (FnGesture.swift), or the first real press surprises.
  it('records from the press, writes after a hold of 0.5 s or more, and treats a shorter press as a possible double-tap', () => {
    expect(gesture('rest', 'down')).toBe('talk');
    expect(gesture('talk', 'up', 500)).toBe('write');
    expect(gesture('talk', 'up', 499)).toBe('wait');
  });

  it('locks hands-free on the second press, writes on the next one, and drops a lone short press', () => {
    expect(gesture('wait', 'down')).toBe('free');
    expect(gesture('free', 'up')).toBe('free');
    expect(gesture('free', 'down')).toBe('write');
    expect(gesture('wait', 'settle')).toBe('rest');
    expect(gesture('write', 'down')).toBe('write');
  });
});
