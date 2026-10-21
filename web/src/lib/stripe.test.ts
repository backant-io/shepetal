import Stripe from 'stripe';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { licenseOf, upsertUser, userById, type User } from './account';
import { db } from './db';
import { checkoutUrl, getStripe, handleWebhook, portalUrl, priceFor } from './stripe';
import { useTestDb } from './test-db';

vi.mock('./db', () => import('./test-db'));
useTestDb();

const SECRET = 'whsec_test_secret';
process.env.STRIPE_SECRET_KEY = 'sk_test_unused';
process.env.STRIPE_WEBHOOK_SECRET = SECRET;
process.env.STRIPE_PRICE_LIFETIME = 'price_lifetime_test';
process.env.STRIPE_PRICE_MONTHLY = 'price_monthly_test';
process.env.STRIPE_PORTAL_CONFIG = 'bpc_test';

const stripe = new Stripe('sk_test_unused');
const DAY = 86_400;
const nowS = () => Math.floor(Date.now() / 1000);
let user: User;
let evtN = 0;

beforeEach(async () => {
  user = await upsertUser('a@example.com');
  vi.spyOn(getStripe().customers, 'create').mockResolvedValue({ id: 'cus_1' } as never);
});
afterEach(() => vi.restoreAllMocks());

const event = (object: object, type = 'checkout.session.completed', id = `evt_${++evtN}`) =>
  JSON.stringify({ id, object: 'event', type, data: { object } });
const session = (over: object = {}) => ({
  id: 'cs_1',
  object: 'checkout.session',
  mode: 'payment',
  client_reference_id: String(user.id),
  customer: 'cus_1',
  metadata: { app: 'shepetal', plan: 'lifetime' },
  payment_status: 'paid',
  ...over,
});
const sign = (payload: string, secret = SECRET) => stripe.webhooks.generateTestHeaderString({ payload, secret });
const send = (payload: string) => handleWebhook(payload, sign(payload));
const fresh = async () => (await userById(user.id))!;
const license = async () => licenseOf(await fresh());

/** A Stripe subscription as subscriptions.retrieve returns it (API 2025-02-24.acacia). */
const sub = (over: Partial<Record<string, unknown>> = {}) =>
  ({
    id: 'sub_1',
    object: 'subscription',
    customer: 'cus_1',
    status: 'active',
    current_period_start: nowS() - DAY,
    current_period_end: nowS() + 29 * DAY,
    cancel_at_period_end: false,
    ended_at: null,
    metadata: { app: 'shepetal', user_id: String(user.id) },
    items: { data: [] },
    ...over,
  }) as unknown as Stripe.Response<Stripe.Subscription>;
const retrieving = (...subs: ReturnType<typeof sub>[]) => {
  const spy = vi.spyOn(getStripe().subscriptions, 'retrieve');
  for (const s of subs) spy.mockResolvedValueOnce(s);
  return spy;
};

describe('lifetime ($23.99 once)', () => {
  it('activates the user forever on a paid, signed checkout.session.completed', async () => {
    const res = await send(event(session()));
    expect(res.status).toBe(200);
    expect(await license()).toMatchObject({ status: 'active', plan: 'lifetime', paid_through: null, renews: false });
  });

  // Anyone can POST to the webhook URL: without Stripe's signature nothing may change.
  it('rejects a bad, missing or tampered signature and changes nothing', async () => {
    const paid = event(session());
    expect((await handleWebhook(paid, sign(paid, 'whsec_someone_else'))).status).toBe(400);
    expect((await handleWebhook(paid, null)).status).toBe(400);
    expect((await handleWebhook(paid, sign(event(session({ client_reference_id: '999' }))))).status).toBe(400);
    expect((await fresh()).status).toBe('trial');
  });

  // The Stripe account is backant's: its own checkouts reach this endpoint too.
  it('ignores checkouts that are not shepetal purchases', async () => {
    expect((await send(event(session({ metadata: {} })))).status).toBe(200);
    expect((await fresh()).status).toBe('trial');
  });

  it('waits for a delayed payment to succeed before activating', async () => {
    await send(event(session({ payment_status: 'unpaid' })));
    expect((await fresh()).status).toBe('trial');
    await send(event(session(), 'checkout.session.async_payment_succeeded'));
    expect((await fresh()).status).toBe('active');
  });

  it('creates a payment-mode session for the one-time price that accepts codes and that the webhook turns into a license', async () => {
    const create = vi.spyOn(getStripe().checkout.sessions, 'create').mockResolvedValue({ url: 'https://checkout.stripe.com/c/pay/cs_1' } as never);
    expect(await checkoutUrl(user, 'https://shepetal.backant.io', 'lifetime')).toBe('https://checkout.stripe.com/c/pay/cs_1');
    const params = create.mock.calls[0][0] as Stripe.Checkout.SessionCreateParams;
    expect(params).toMatchObject({
      mode: 'payment',
      line_items: [{ price: 'price_lifetime_test', quantity: 1 }],
      allow_promotion_codes: true,
      customer: 'cus_1',
      client_reference_id: String(user.id),
      metadata: { app: 'shepetal', plan: 'lifetime', user_id: String(user.id) },
    });
    expect(params.subscription_data).toBeUndefined();
    await send(event(session({ client_reference_id: params.client_reference_id, metadata: params.metadata })));
    expect((await fresh()).status).toBe('active');
  });

  it('keeps one Stripe customer per user, so the PRODUCTHUNT code (first transaction only) works once per user', async () => {
    const create = vi.spyOn(getStripe().checkout.sessions, 'create').mockResolvedValue({ url: 'https://x' } as never);
    await checkoutUrl(user, 'https://s', 'lifetime');
    await checkoutUrl(await fresh(), 'https://s', 'monthly');
    expect(getStripe().customers.create).toHaveBeenCalledTimes(1);
    expect(getStripe().customers.create).toHaveBeenCalledWith(
      { email: 'a@example.com', metadata: { app: 'shepetal', user_id: String(user.id) } },
      { idempotencyKey: `shepetal-customer-${user.id}-${user.trial_started_at}` },
    );
    expect(create.mock.calls.map((c) => (c[0] as Stripe.Checkout.SessionCreateParams).customer)).toEqual(['cus_1', 'cus_1']);
    expect((await fresh()).stripe_customer_id).toBe('cus_1');
  });

  it('stops a running subscription from renewing when its owner buys the lifetime license', async () => {
    retrieving(sub());
    await send(event(sub(), 'customer.subscription.updated'));
    const update = vi.spyOn(getStripe().subscriptions, 'update').mockResolvedValue({} as never);
    await send(event(session()));
    expect(update).toHaveBeenCalledWith('sub_1', { cancel_at_period_end: true });
    expect(await license()).toMatchObject({ status: 'active', plan: 'lifetime' });
  });
});

describe('subscription ($0.99 a month)', () => {
  it('creates a subscription-mode session for the monthly price, tagged so its subscription events are found', async () => {
    const create = vi.spyOn(getStripe().checkout.sessions, 'create').mockResolvedValue({ url: 'https://checkout.stripe.com/c/pay/cs_2' } as never);
    await checkoutUrl(user, 'https://shepetal.backant.io', 'monthly');
    const params = create.mock.calls[0][0] as Stripe.Checkout.SessionCreateParams;
    expect(params).toMatchObject({
      mode: 'subscription',
      line_items: [{ price: 'price_monthly_test', quantity: 1 }],
      allow_promotion_codes: true,
      customer: 'cus_1',
      metadata: { app: 'shepetal', plan: 'monthly', user_id: String(user.id) },
      subscription_data: { metadata: { app: 'shepetal', user_id: String(user.id) } },
    });
    expect(params.payment_intent_data).toBeUndefined();
    // backant.io's handler on the same account takes any subscription checkout's client_reference_id as its own client.
    expect(params.client_reference_id).toBeUndefined();
  });

  it('turns a completed subscription checkout into an active subscription, paid through the period end', async () => {
    const s = sub();
    const spy = retrieving(s);
    await send(event(session({ mode: 'subscription', subscription: 'sub_1', payment_status: 'paid', client_reference_id: null, metadata: { app: 'shepetal', plan: 'monthly', user_id: String(user.id) } })));
    expect(spy).toHaveBeenCalledWith('sub_1');
    const u = await fresh();
    expect(u).toMatchObject({ plan: 'subscription', sub_id: 'sub_1', sub_status: 'active', cancel_at_period_end: 0, stripe_customer_id: 'cus_1' });
    expect(u.current_period_end).toBe(new Date(s.current_period_end * 1000).toISOString());
    expect(licenseOf(u)).toMatchObject({ status: 'active', plan: 'subscription', renews: true, payment_failed: false, trial_ends_at: null, paid_through: u.current_period_end });
  });

  it('keeps a cancelled subscription working until its period ends, then ends it', async () => {
    const end = nowS() + 10 * DAY;
    retrieving(sub({ current_period_end: end, cancel_at_period_end: true }));
    await send(event(sub(), 'customer.subscription.updated'));
    expect(await license()).toMatchObject({ status: 'active', plan: 'subscription', renews: false });
    const ended = sub({ status: 'canceled', current_period_end: end, cancel_at_period_end: true, ended_at: end });
    retrieving(ended);
    await send(event(ended, 'customer.subscription.deleted'));
    const u = await fresh();
    expect(licenseOf(u, end * 1000 - 1000).status).toBe('active');
    // The trial ended long ago for this check: after the period the license is expired.
    expect(licenseOf({ ...u, trial_started_at: '2026-01-01T00:00:00.000Z' }, end * 1000 + 1000)).toMatchObject({ status: 'expired', plan: 'subscription', renews: false });
  });

  it('stops a subscription whose renewal failed at the start of the unpaid period, and starts it again once paid', async () => {
    const start = nowS() - 3600;
    retrieving(sub({ current_period_start: start }));
    await send(event(sub(), 'customer.subscription.updated'));
    // invoice.payment_failed arrives while the subscription still says active: the open invoice decides.
    retrieving(sub({ current_period_start: start }));
    vi.spyOn(getStripe().invoices, 'retrieve').mockResolvedValue({ id: 'in_1', status: 'open' } as never);
    const failed = { id: 'in_1', object: 'invoice', status: 'open', subscription: 'sub_1', subscription_details: { metadata: { app: 'shepetal' } } };
    await send(event(failed, 'invoice.payment_failed'));
    let u = await fresh();
    expect(u.sub_status).toBe('past_due');
    expect(u.paid_through).toBe(new Date(start * 1000).toISOString());
    expect(licenseOf({ ...u, trial_started_at: '2026-01-01T00:00:00.000Z' })).toMatchObject({ status: 'expired', plan: 'subscription', payment_failed: true, renews: true });
    // The retry (or a new card in the portal) pays it.
    retrieving(sub({ current_period_start: start }));
    await send(event({ ...failed, status: 'paid' }, 'invoice.paid'));
    u = await fresh();
    expect(licenseOf(u)).toMatchObject({ status: 'active', payment_failed: false });
  });

  it('reads the subscription of an invoice on newer API versions (parent.subscription_details)', async () => {
    const spy = retrieving(sub());
    await send(event({ id: 'in_2', object: 'invoice', parent: { subscription_details: { subscription: 'sub_1', metadata: { app: 'shepetal' } } } }, 'invoice.paid'));
    expect(spy).toHaveBeenCalledWith('sub_1');
    expect((await license()).status).toBe('active');
  });

  it("ignores backant's own subscriptions and invoices without fetching them", async () => {
    const spy = vi.spyOn(getStripe().subscriptions, 'retrieve');
    await send(event(sub({ metadata: {} }), 'customer.subscription.updated'));
    await send(event({ id: 'in_3', object: 'invoice', subscription: 'sub_9', subscription_details: { metadata: { product: 'vibe' } } }, 'invoice.paid'));
    expect(spy).not.toHaveBeenCalled();
    expect((await license()).plan).toBe('trial');
  });

  it('never lets a late event of an ended subscription replace the current one', async () => {
    retrieving(sub({ id: 'sub_new' }));
    await send(event(sub({ id: 'sub_new' }), 'customer.subscription.updated'));
    const old = sub({ id: 'sub_old', status: 'canceled', ended_at: nowS() - DAY });
    retrieving(old);
    await send(event(old, 'customer.subscription.deleted'));
    expect(await fresh()).toMatchObject({ sub_id: 'sub_new', sub_status: 'active' });
    expect((await license()).status).toBe('active');
  });

  it("opens the Billing Portal for the user's customer with shepetal's configuration", async () => {
    expect(await portalUrl(user, 'https://s')).toBeNull();
    const create = vi.spyOn(getStripe().billingPortal.sessions, 'create').mockResolvedValue({ url: 'https://billing.stripe.com/p/session/1' } as never);
    expect(await portalUrl({ ...user, stripe_customer_id: 'cus_1' }, 'https://shepetal.backant.io')).toBe('https://billing.stripe.com/p/session/1');
    expect(create).toHaveBeenCalledWith({ customer: 'cus_1', configuration: 'bpc_test', return_url: 'https://shepetal.backant.io/account' });
  });
});

describe('each event once', () => {
  it('handles a redelivered event id only once', async () => {
    const spy = retrieving(sub(), sub());
    const payload = event(sub(), 'customer.subscription.updated', 'evt_same');
    expect(await (await send(payload)).json()).toEqual({ received: true });
    expect(await (await send(payload)).json()).toEqual({ received: true, duplicate: true });
    expect(spy).toHaveBeenCalledTimes(1);
    expect((await db().prepare('SELECT count(*) AS n FROM stripe_events').first())?.n).toBe(1);
  });

  it('answers 500 and forgets the event when handling fails, so Stripe retries it', async () => {
    const spy = vi.spyOn(getStripe().subscriptions, 'retrieve').mockRejectedValueOnce(new Error('Stripe is down'));
    const payload = event(sub(), 'customer.subscription.updated', 'evt_retry');
    expect((await send(payload)).status).toBe(500);
    spy.mockResolvedValueOnce(sub());
    expect((await send(payload)).status).toBe(200);
    expect((await license()).status).toBe('active');
  });

  it('ignores event types it does not handle, without recording them', async () => {
    expect((await send(event({ id: 'pi_1' }, 'payment_intent.succeeded'))).status).toBe(200);
    expect((await db().prepare('SELECT count(*) AS n FROM stripe_events').first())?.n).toBe(0);
  });
});

it('finds the prices by lookup key when no override is set', async () => {
  delete process.env.STRIPE_PRICE_MONTHLY;
  const list = vi.spyOn(getStripe().prices, 'list').mockResolvedValue({ data: [{ id: 'price_found' }] } as never);
  expect(await priceFor('monthly')).toBe('price_found');
  expect(await priceFor('monthly')).toBe('price_found');
  expect(list).toHaveBeenCalledTimes(1);
  expect(list).toHaveBeenCalledWith({ lookup_keys: ['shepetal_monthly'], active: true, limit: 1 });
  process.env.STRIPE_PRICE_MONTHLY = 'price_monthly_test';
});
