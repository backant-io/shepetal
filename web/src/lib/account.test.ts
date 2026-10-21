import { describe, expect, it, vi } from 'vitest';
import { licenseOf, paidThrough, planSettings, upsertUser, type Subscription, type User } from './account';
import { useTestDb } from './test-db';

vi.mock('./db', () => import('./test-db'));
useTestDb();

const DAY = 86_400_000;
const start = '2026-01-01T00:00:00.000Z';
const t0 = Date.parse(start);
const user = (over: Partial<User> = {}): User => ({
  id: 1,
  email: 'a@example.com',
  trial_started_at: start,
  status: 'trial',
  purchased_at: null,
  ...over,
});

// The product promise: 30 free days, counted from the first sign-in. Day 30 is the first day without it.
it.each([
  [0, 'trial'],
  [29, 'trial'],
  [30, 'expired'],
  [31, 'expired'],
])('on day %i after the first sign-in the license is %s', (day, status) => {
  expect(licenseOf(user(), t0 + day * DAY)).toEqual({
    status,
    plan: 'trial',
    trial_ends_at: '2026-01-31T00:00:00.000Z',
    paid_through: null,
    renews: false,
    payment_failed: false,
    email: 'a@example.com',
  });
});

it('gives a free trial of exactly 30 days from the first sign-in', () => {
  expect(licenseOf(user(), t0 + 30 * DAY - 1).status).toBe('trial');
  expect(licenseOf(user(), t0 + 30 * DAY).status).toBe('expired');
});

it('keeps a purchase active forever, long after the trial ended', () => {
  expect(licenseOf(user({ status: 'active' }), t0 + 3650 * DAY)).toEqual({
    status: 'active',
    plan: 'lifetime',
    trial_ends_at: null,
    paid_through: null,
    renews: false,
    payment_failed: false,
    email: 'a@example.com',
  });
});

const subscriber = (over: Partial<User> = {}) =>
  user({ plan: 'subscription', sub_id: 'sub_1', sub_status: 'active', cancel_at_period_end: 0, paid_through: '2026-03-01T00:00:00.000Z', ...over });

it('keeps a subscription active until paid_through, then falls back to the trial dates', () => {
  const end = Date.parse('2026-03-01T00:00:00.000Z');
  expect(licenseOf(subscriber(), end - 1)).toEqual({
    status: 'active',
    plan: 'subscription',
    trial_ends_at: null,
    paid_through: '2026-03-01T00:00:00.000Z',
    renews: true,
    payment_failed: false,
    email: 'a@example.com',
  });
  expect(licenseOf(subscriber(), end)).toMatchObject({ status: 'expired', plan: 'subscription', trial_ends_at: '2026-01-31T00:00:00.000Z' });
  // A subscription that lapses inside the 30 days leaves the trial running.
  expect(licenseOf(subscriber({ paid_through: '2026-01-10T00:00:00.000Z' }), t0 + 15 * DAY).status).toBe('trial');
});

it('says a cancelled subscription will not renew and a failed renewal needs a new card', () => {
  expect(licenseOf(subscriber({ cancel_at_period_end: 1 }), t0)).toMatchObject({ status: 'active', renews: false });
  expect(licenseOf(subscriber({ sub_status: 'past_due' }), t0)).toMatchObject({ renews: true, payment_failed: true });
  expect(licenseOf(subscriber({ sub_status: 'canceled' }), t0)).toMatchObject({ renews: false, payment_failed: false });
});

it('a lifetime license wins over any subscription state', () => {
  expect(licenseOf(subscriber({ status: 'active', plan: 'lifetime', sub_status: 'past_due', paid_through: '2026-01-02T00:00:00.000Z' }), t0 + 3650 * DAY))
    .toMatchObject({ status: 'active', plan: 'lifetime', paid_through: null });
});

describe('paid_through from a Stripe subscription', () => {
  const s = (status: string, over: Partial<Subscription> = {}): Subscription => ({
    id: 'sub_1',
    status,
    current_period_start: 1_000_000,
    current_period_end: 2_000_000,
    cancel_at_period_end: false,
    ended_at: null,
    ...over,
  });
  const at = (sec: number) => new Date(sec * 1000).toISOString();

  it('is the period end while active or trialing', () => {
    expect(paidThrough(s('active'), null)).toBe(at(2_000_000));
    expect(paidThrough(s('trialing'), at(5))).toBe(at(2_000_000));
  });
  it('is the start of the unpaid period while a renewal is unpaid', () => {
    for (const st of ['past_due', 'unpaid', 'paused']) expect(paidThrough(s(st), at(2_000_000))).toBe(at(1_000_000));
  });
  it('is when it ended once cancelled, never later than what was paid', () => {
    expect(paidThrough(s('canceled', { ended_at: 1_500_000 }), at(2_000_000))).toBe(at(1_500_000));
    expect(paidThrough(s('canceled', { ended_at: 1_800_000 }), at(1_000_000))).toBe(at(1_000_000));
    expect(paidThrough(s('canceled', { ended_at: null }), null)).toBe(at(2_000_000));
  });
  it('adds nothing for a first payment that did not go through', () => {
    expect(paidThrough(s('incomplete'), null)).toBeNull();
    expect(paidThrough(s('incomplete_expired'), null)).toBeNull();
  });
});

// Signing in again (web or another device) must never hand out a fresh trial.
it('starts the trial at the first sign-in and never restarts it', async () => {
  const first = await upsertUser(' New@Example.com ');
  await new Promise((r) => setTimeout(r, 20));
  const again = await upsertUser('new@example.com');
  expect(first.email).toBe('new@example.com');
  expect(again.id).toBe(first.id);
  expect(again.trial_started_at).toBe(first.trial_started_at);
  expect(Math.abs(Date.parse(first.trial_started_at) - Date.now())).toBeLessThan(5_000);
});

describe('plan settings (GET /api/account/plan)', () => {
  it('shows the trial with its days left, and offers the plans', () => {
    expect(planSettings(user(), t0 + 17.5 * DAY)).toEqual({
      plan: 'trial',
      status: 'trial',
      email: 'a@example.com',
      trial: { ends_at: '2026-01-31T00:00:00.000Z', days_left: 13 },
      lifetime: null,
      subscription: null,
      actions: { cancel: false, resume: false, switch_to_lifetime: false, portal: false, choose_plan: true },
    });
    expect(planSettings(user(), t0 + 31 * DAY)).toMatchObject({ status: 'expired', trial: null, actions: { choose_plan: true } });
  });

  it('shows the lifetime license, with nothing to cancel', () => {
    expect(planSettings(user({ status: 'active', plan: 'lifetime', purchased_at: '2026-01-05T00:00:00.000Z', stripe_customer_id: 'cus_1' }), t0)).toEqual({
      plan: 'lifetime',
      status: 'active',
      email: 'a@example.com',
      trial: null,
      lifetime: { purchased_at: '2026-01-05T00:00:00.000Z' },
      subscription: null,
      actions: { cancel: false, resume: false, switch_to_lifetime: false, portal: true, choose_plan: false },
    });
  });

  it('shows an active subscription with its next billing date and amount, and offers cancel and lifetime', () => {
    const u = subscriber({ sub_amount: 99, sub_currency: 'usd', stripe_customer_id: 'cus_1' });
    expect(planSettings(u, t0 + 40 * DAY)).toEqual({
      plan: 'subscription',
      status: 'active',
      email: 'a@example.com',
      trial: null,
      lifetime: null,
      subscription: {
        status: 'active',
        paid_through: '2026-03-01T00:00:00.000Z',
        next_billing_date: '2026-03-01T00:00:00.000Z',
        ends_at: null,
        amount: 99,
        currency: 'usd',
        amount_display: '$0.99',
        interval: 'month',
      },
      actions: { cancel: true, resume: false, switch_to_lifetime: true, portal: true, choose_plan: false },
    });
  });

  it('shows a cancelled subscription as ending at its period end, with resume', () => {
    const s = planSettings(subscriber({ cancel_at_period_end: 1, sub_amount: 99, sub_currency: 'usd' }), t0 + 40 * DAY);
    expect(s.status).toBe('active');
    expect(s.subscription).toMatchObject({ status: 'cancels_at_period_end', next_billing_date: null, ends_at: '2026-03-01T00:00:00.000Z' });
    expect(s.actions).toMatchObject({ cancel: false, resume: true, switch_to_lifetime: true });
  });

  it('shows a failed renewal as past due and an ended one as ended', () => {
    const due = planSettings(subscriber({ sub_status: 'past_due', paid_through: '2026-02-01T00:00:00.000Z' }), t0 + 40 * DAY);
    expect(due.subscription).toMatchObject({ status: 'past_due', next_billing_date: null });
    expect(due.actions).toMatchObject({ cancel: true, switch_to_lifetime: true, choose_plan: false });
    const ended = planSettings(subscriber({ sub_status: 'canceled', paid_through: '2026-02-01T00:00:00.000Z' }), t0 + 40 * DAY);
    expect(ended).toMatchObject({ status: 'expired', subscription: { status: 'ended', ends_at: '2026-02-01T00:00:00.000Z' } });
    expect(ended.actions).toMatchObject({ cancel: false, resume: false, switch_to_lifetime: false, choose_plan: true });
  });
});
