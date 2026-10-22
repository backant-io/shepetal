import Stripe from 'stripe';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { licenseOf, upsertUser, userById, type User } from './account';
import { db } from './db';
import { checkoutUrl, CONFIRMATION, consentText, getStripe, handleWebhook, nextCharge, portalUrl, priceFor, setCancelAtPeriodEnd } from './stripe';
import { SITE_URL } from './site';
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
  vi.spyOn(getStripe().checkout.sessions, 'list').mockImplementation(() => none() as never);
});
afterEach(() => vi.restoreAllMocks());

/** An empty Stripe list (auto-pagination), or one with these items. */
const none = (...items: object[]) => ({ async *[Symbol.asyncIterator]() { yield* items; } });
const event = (object: object, type = 'checkout.session.completed', id = `evt_${++evtN}`) =>
  JSON.stringify({ id, object: 'event', type, created: Math.floor(Date.now() / 1000), data: { object } });
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

  it('keeps when the buyer consented to delivery right away', async () => {
    await send(event(session({ consent: { terms_of_service: 'accepted' } })));
    expect((await fresh()).withdrawal_waived_at).toMatch(/^\d{4}-\d\d-\d\dT/);
  });

  it('waits for a delayed payment to succeed before activating', async () => {
    await send(event(session({ payment_status: 'unpaid' })));
    expect((await fresh()).status).toBe('trial');
    await send(event(session(), 'checkout.session.async_payment_succeeded'));
    expect((await fresh()).status).toBe('active');
  });

  it('creates a payment-mode session for the one-time price that accepts codes and that the webhook turns into a license', async () => {
    const create = vi.spyOn(getStripe().checkout.sessions, 'create').mockResolvedValue({ url: 'https://checkout.stripe.com/c/pay/cs_1' } as never);
    expect(await checkoutUrl(user, SITE_URL, 'lifetime')).toBe('https://checkout.stripe.com/c/pay/cs_1');
    const params = create.mock.calls[0][0] as Stripe.Checkout.SessionCreateParams;
    expect(params).toMatchObject({
      mode: 'payment',
      line_items: [{ price: 'price_lifetime_test', quantity: 1 }],
      customer: 'cus_1',
      client_reference_id: String(user.id),
      metadata: { app: 'shepetal', plan: 'lifetime', user_id: String(user.id) },
    });
    expect(params.subscription_data).toBeUndefined();
    // Stripe's own code field stays off: backant.io's codes on the shared account (some 100% off) must not apply.
    expect(params.allow_promotion_codes).toBeUndefined();
    expect(params.discounts).toBeUndefined();
    // Stripe Tax, and the EU consent to delivery right away (which ends the 14-day withdrawal right).
    expect(params).toMatchObject({
      automatic_tax: { enabled: true },
      customer_update: { address: 'auto', name: 'auto' },
      tax_id_collection: { enabled: true },
      consent_collection: { terms_of_service: 'required' },
      custom_text: { terms_of_service_acceptance: { message: consentText('lifetime', SITE_URL) } },
    });
    expect((params.custom_text?.terms_of_service_acceptance as { message: string } | undefined)?.message).toMatch(/delivered right away.*ends my 14-day right of withdrawal/);
    expect(params.payment_intent_data?.description).toContain('ends the 14-day right of withdrawal');
    await send(event(session({ client_reference_id: params.client_reference_id, metadata: params.metadata })));
    expect((await fresh()).status).toBe('active');
  });

  it('keeps one Stripe customer per user, so the PRODUCTHUNT code (first transaction only) works once per user', async () => {
    const create = vi.spyOn(getStripe().checkout.sessions, 'create').mockResolvedValue({ url: 'https://x' } as never);
    await checkoutUrl(user, 'https://s', 'lifetime');
    await checkoutUrl(await fresh(), 'https://s', 'monthly');
    expect(getStripe().customers.create).toHaveBeenCalledTimes(1);
    expect(getStripe().customers.create).toHaveBeenCalledWith(
      { email: 'a@example.com', metadata: { app: 'shepetal', user_id: String(user.id) }, invoice_settings: { footer: CONFIRMATION } },
      { idempotencyKey: `shepetal-customer-${user.id}-${user.trial_started_at}` },
    );
    expect(create.mock.calls.map((c) => (c[0] as Stripe.Checkout.SessionCreateParams).customer)).toEqual(['cus_1', 'cus_1']);
    expect((await fresh()).stripe_customer_id).toBe('cus_1');
  });

  it('ends a running subscription at once, with no further charge, when its owner switches to lifetime', async () => {
    retrieving(sub());
    await send(event(sub(), 'customer.subscription.updated'));
    const ended = sub({ status: 'canceled', ended_at: nowS() });
    const retrieve = retrieving(sub(), ended, ended, ended);
    const cancel = vi.spyOn(getStripe().subscriptions, 'cancel').mockResolvedValue(ended as never);
    const list = vi.spyOn(getStripe().invoices, 'list').mockImplementation(
      () => ({ async *[Symbol.asyncIterator]() { yield { id: 'in_open' }; } }) as never,
    );
    const voided = vi.spyOn(getStripe().invoices, 'voidInvoice').mockResolvedValue({} as never);
    const paid = event(session(), 'checkout.session.completed', 'evt_switch');
    await send(paid);
    expect(cancel).toHaveBeenCalledTimes(1);
    expect(cancel).toHaveBeenCalledWith('sub_1', { invoice_now: false, prorate: false }, { idempotencyKey: 'shepetal-end-sub_1' });
    expect(list).toHaveBeenCalledWith({ subscription: 'sub_1', status: 'open', limit: 100 });
    expect(voided).toHaveBeenCalledWith('in_open');
    expect(await fresh()).toMatchObject({ status: 'active', plan: 'lifetime', sub_status: 'canceled' });
    expect(await license()).toMatchObject({ status: 'active', plan: 'lifetime', renews: false });
    // Stripe delivers it again, or the delayed-payment event follows: nothing is cancelled twice.
    expect(await (await send(paid)).json()).toEqual({ received: true, duplicate: true });
    await send(event(session(), 'checkout.session.async_payment_succeeded'));
    expect(cancel).toHaveBeenCalledTimes(1);
    expect(retrieve).toHaveBeenCalled();
  });

  it('also ends a subscription already cancelled to its period end, so it never runs beside the lifetime license', async () => {
    retrieving(sub({ cancel_at_period_end: true }));
    await send(event(sub(), 'customer.subscription.updated'));
    const ended = sub({ status: 'canceled', ended_at: nowS() });
    retrieving(sub({ cancel_at_period_end: true }), ended);
    const cancel = vi.spyOn(getStripe().subscriptions, 'cancel').mockResolvedValue(ended as never);
    vi.spyOn(getStripe().invoices, 'list').mockImplementation(() => ({ async *[Symbol.asyncIterator]() {} }) as never);
    await send(event(session()));
    expect(cancel).toHaveBeenCalledTimes(1);
    expect((await license()).plan).toBe('lifetime');
  });
});

describe('the PRODUCTHUNT code', () => {
  const promo = (code: string, app?: string) => ({ id: `promo_${code}`, code, coupon: { id: 'c', metadata: app ? { app } : {} } });

  it('puts a shepetal code on the lifetime session as a discount', async () => {
    const list = vi.spyOn(getStripe().promotionCodes, 'list').mockResolvedValue({ data: [promo('PRODUCTHUNT', 'shepetal')] } as never);
    const create = vi.spyOn(getStripe().checkout.sessions, 'create').mockResolvedValue({ url: 'https://x' } as never);
    await checkoutUrl(user, 'https://s', 'lifetime', ' PRODUCTHUNT ');
    expect(list).toHaveBeenCalledWith({ code: 'PRODUCTHUNT', active: true, limit: 10 });
    const params = create.mock.calls[0][0] as Stripe.Checkout.SessionCreateParams;
    expect(params.discounts).toEqual([{ promotion_code: 'promo_PRODUCTHUNT' }]);
    expect(params.allow_promotion_codes).toBeUndefined();
  });

  it('refuses any code on the monthly plan, before asking Stripe', async () => {
    const list = vi.spyOn(getStripe().promotionCodes, 'list');
    const create = vi.spyOn(getStripe().checkout.sessions, 'create');
    await expect(checkoutUrl(user, 'https://s', 'monthly', 'PRODUCTHUNT')).rejects.toMatchObject({ code: 'code_lifetime_only' });
    expect(list).not.toHaveBeenCalled();
    expect(create).not.toHaveBeenCalled();
  });

  it("refuses backant.io's codes on the shared account, even 100% off ones", async () => {
    vi.spyOn(getStripe().promotionCodes, 'list').mockResolvedValue({ data: [promo('PRODUCTHUNT100')] } as never);
    const create = vi.spyOn(getStripe().checkout.sessions, 'create');
    await expect(checkoutUrl(user, 'https://s', 'lifetime', 'PRODUCTHUNT100')).rejects.toMatchObject({ code: 'invalid_code' });
    expect(create).not.toHaveBeenCalled();
  });

  it("says when Stripe refuses the code (used before, ended, a customer who has paid)", async () => {
    vi.spyOn(getStripe().promotionCodes, 'list').mockResolvedValue({ data: [promo('PRODUCTHUNT', 'shepetal')] } as never);
    vi.spyOn(getStripe().checkout.sessions, 'create').mockRejectedValue(
      new Stripe.errors.StripeInvalidRequestError({ message: 'This promotion code cannot be redeemed because the associated customer has prior transactions.' } as never),
    );
    await expect(checkoutUrl(user, 'https://s', 'lifetime', 'PRODUCTHUNT')).rejects.toMatchObject({ code: 'code_not_applicable' });
  });

  it('expires the open sessions of the customer first, so a second tab cannot pay twice', async () => {
    vi.spyOn(getStripe().checkout.sessions, 'list').mockImplementation(
      () => none({ id: 'cs_old', metadata: { app: 'shepetal' } }, { id: 'cs_backant', metadata: {} }) as never,
    );
    const expire = vi.spyOn(getStripe().checkout.sessions, 'expire').mockResolvedValue({} as never);
    vi.spyOn(getStripe().checkout.sessions, 'create').mockResolvedValue({ url: 'https://x' } as never);
    await checkoutUrl(user, 'https://s', 'monthly');
    expect(getStripe().checkout.sessions.list).toHaveBeenCalledWith({ customer: 'cus_1', status: 'open', limit: 100 });
    expect(expire).toHaveBeenCalledTimes(1);
    expect(expire).toHaveBeenCalledWith('cs_old');
  });
});

describe('never charged twice', () => {
  const stubEnd = (ended: object) => {
    const cancel = vi.spyOn(getStripe().subscriptions, 'cancel').mockResolvedValue(ended as never);
    vi.spyOn(getStripe().invoices, 'list').mockImplementation(((p: { status: string }) =>
      p.status === 'paid' ? none({ id: 'in_paid', amount_paid: 99, payment_intent: 'pi_sub' }) : none()) as never);
    const refund = vi.spyOn(getStripe().refunds, 'create').mockResolvedValue({} as never);
    return { cancel, refund };
  };

  it('ends and refunds a subscription paid by an owner of the lifetime license (a second tab)', async () => {
    await send(event(session({ payment_intent: 'pi_life' })));
    const later = sub({ created: nowS() + 60 }); // made after the lifetime purchase
    const ended = sub({ status: 'canceled', ended_at: nowS() });
    retrieving(later, later, ended);
    const { cancel, refund } = stubEnd(ended);
    await send(event(later, 'customer.subscription.updated'));
    expect(cancel).toHaveBeenCalledWith('sub_1', { invoice_now: false, prorate: false }, { idempotencyKey: 'shepetal-end-sub_1' });
    expect(refund).toHaveBeenCalledWith(
      { payment_intent: 'pi_sub', metadata: { app: 'shepetal', reason: 'duplicate_subscription' } },
      { idempotencyKey: 'shepetal-refund-pi_sub' },
    );
    expect(await license()).toMatchObject({ status: 'active', plan: 'lifetime' });
  });

  it('keeps the first of two subscriptions and ends and refunds the later one', async () => {
    retrieving(sub({ id: 'sub_A', created: 100 }));
    await send(event(sub({ id: 'sub_A' }), 'customer.subscription.updated'));
    const later = sub({ id: 'sub_B', created: 200 });
    const endedB = sub({ id: 'sub_B', status: 'canceled', created: 200, ended_at: nowS() });
    // sync sub_B, then the stored sub_A, then endSubscription(sub_B) reads it twice.
    retrieving(later, sub({ id: 'sub_A', created: 100 }), later, endedB);
    const { cancel, refund } = stubEnd(endedB);
    await send(event(later, 'customer.subscription.updated'));
    expect(cancel).toHaveBeenCalledWith('sub_B', expect.anything(), expect.anything());
    expect(refund).toHaveBeenCalledTimes(1);
    expect(await fresh()).toMatchObject({ sub_id: 'sub_A', sub_status: 'active' });
    // sub_B's own deleted event later changes nothing.
    retrieving(endedB);
    await send(event(endedB, 'customer.subscription.deleted'));
    expect(await fresh()).toMatchObject({ sub_id: 'sub_A', sub_status: 'active' });
  });

  it('refunds a second lifetime payment and keeps the first', async () => {
    await send(event(session({ payment_intent: 'pi_first' })));
    const refund = vi.spyOn(getStripe().refunds, 'create').mockResolvedValue({} as never);
    await send(event(session({ id: 'cs_2', payment_intent: 'pi_second' })));
    expect(refund).toHaveBeenCalledWith(
      { payment_intent: 'pi_second', metadata: { app: 'shepetal', reason: 'duplicate_lifetime' } },
      { idempotencyKey: 'shepetal-refund-pi_second' },
    );
    // A retry of the first purchase refunds nothing.
    await send(event(session({ payment_intent: 'pi_first' })));
    expect(refund).toHaveBeenCalledTimes(1);
    expect((await fresh()).lifetime_payment_intent).toBe('pi_first');
  });

  it('ends the lifetime license when its payment is refunded, and ignores refunds of other payments', async () => {
    await send(event(session({ payment_intent: 'pi_life' })));
    await send(event({ id: 'ch_1', object: 'charge', payment_intent: 'pi_other', refunded: true }, 'charge.refunded'));
    expect((await license()).plan).toBe('lifetime');
    await send(event({ id: 'ch_2', object: 'charge', payment_intent: 'pi_life', refunded: false }, 'charge.refunded'));
    expect((await license()).plan).toBe('lifetime'); // a partial refund keeps it
    await send(event({ id: 'ch_3', object: 'charge', payment_intent: 'pi_life', refunded: true }, 'charge.refunded'));
    expect(await license()).toMatchObject({ plan: 'trial', status: 'trial' });
  });

  it('refunds nothing when a re-bought lifetime purchase is handled again, and its refund ends it', async () => {
    const refund = vi.spyOn(getStripe().refunds, 'create').mockResolvedValue({} as never);
    await send(event(session({ payment_intent: 'pi_A' })));
    await send(event({ id: 'ch_A', object: 'charge', payment_intent: 'pi_A', refunded: true }, 'charge.refunded'));
    expect((await license()).plan).toBe('trial');
    await send(event(session({ id: 'cs_B', payment_intent: 'pi_B' })));
    await send(event(session({ id: 'cs_B', payment_intent: 'pi_B' }))); // run again (a resend: a new event id)
    expect(refund).not.toHaveBeenCalled();
    expect((await fresh()).lifetime_payment_intent).toBe('pi_B');
    await send(event({ id: 'ch_B', object: 'charge', payment_intent: 'pi_B', refunded: true }, 'charge.refunded'));
    expect((await license()).plan).toBe('trial');
  });

  it('never refunds a purchase from before the plans when its event runs again', async () => {
    await db().prepare("UPDATE users SET status = 'active', plan = 'lifetime', purchased_at = '2026-10-01T00:00:00.000Z' WHERE id = ?1").bind(user.id).run();
    const refund = vi.spyOn(getStripe().refunds, 'create').mockResolvedValue({} as never);
    await send(event(session({ payment_intent: 'pi_legacy' })));
    expect(refund).not.toHaveBeenCalled();
    expect((await fresh()).lifetime_payment_intent).toBe('pi_legacy');
  });

  it('keeps the past months of a subscription that began before the lifetime purchase (a switch whose cancel failed)', async () => {
    retrieving(sub({ created: nowS() - 90 * DAY }));
    await send(event(sub(), 'customer.subscription.updated'));
    await db().prepare("UPDATE users SET status = 'active', plan = 'lifetime', purchased_at = ?2 WHERE id = ?1").bind(user.id, new Date().toISOString()).run();
    const old = sub({ created: nowS() - 90 * DAY });
    const ended = sub({ status: 'canceled', created: nowS() - 90 * DAY, ended_at: nowS() });
    retrieving(old, old, ended);
    const { cancel, refund } = stubEnd(ended);
    await send(event(old, 'customer.subscription.updated'));
    expect(cancel).toHaveBeenCalledTimes(1);
    expect(refund).not.toHaveBeenCalled();
  });

  it('refunds one of two lifetime payments handled at the same moment', async () => {
    const refund = vi.spyOn(getStripe().refunds, 'create').mockResolvedValue({} as never);
    await Promise.all([send(event(session({ id: 'cs_x', payment_intent: 'pi_x' }))), send(event(session({ id: 'cs_y', payment_intent: 'pi_y' })))]);
    expect(refund).toHaveBeenCalledTimes(1);
    const kept = (await fresh()).lifetime_payment_intent;
    expect(refund.mock.calls[0][0]).toMatchObject({ payment_intent: kept === 'pi_x' ? 'pi_y' : 'pi_x' });
  });

  it('keeps a paid-up subscription over an older one in arrears, which just stops', async () => {
    retrieving(sub({ id: 'sub_A', created: 100, status: 'past_due' }));
    await send(event(sub({ id: 'sub_A' }), 'customer.subscription.updated'));
    const b = sub({ id: 'sub_B', created: 200 });
    const endedA = sub({ id: 'sub_A', status: 'canceled', created: 100, ended_at: nowS() });
    retrieving(b, sub({ id: 'sub_A', created: 100, status: 'past_due' }), sub({ id: 'sub_A', created: 100, status: 'past_due' }), endedA);
    const { cancel, refund } = stubEnd(endedA);
    await send(event(b, 'customer.subscription.updated'));
    expect(cancel).toHaveBeenCalledWith('sub_A', expect.anything(), expect.anything());
    expect(refund).not.toHaveBeenCalled();
    expect(await fresh()).toMatchObject({ sub_id: 'sub_B', sub_status: 'active' });
    expect((await license()).status).toBe('active');
  });

  it('treats a refund Stripe already made (after its 24 h idempotency window) as done', async () => {
    await send(event(session({ payment_intent: 'pi_first' })));
    vi.spyOn(getStripe().refunds, 'create').mockRejectedValue(
      new Stripe.errors.StripeInvalidRequestError({ code: 'charge_already_refunded', message: 'Charge has already been refunded.' } as never),
    );
    expect((await send(event(session({ id: 'cs_2', payment_intent: 'pi_second' })))).status).toBe(200);
  });

  it('never shows a subscription that was never paid as one that ended', async () => {
    retrieving(sub({ status: 'incomplete_expired' }));
    await send(event(sub(), 'customer.subscription.updated'));
    expect((await license()).plan).toBe('trial');
  });
});

describe('subscription ($0.99 a month)', () => {
  it('creates a subscription-mode session for the monthly price, tagged so its subscription events are found', async () => {
    const create = vi.spyOn(getStripe().checkout.sessions, 'create').mockResolvedValue({ url: 'https://checkout.stripe.com/c/pay/cs_2' } as never);
    await checkoutUrl(user, SITE_URL, 'monthly');
    const params = create.mock.calls[0][0] as Stripe.Checkout.SessionCreateParams;
    expect(params).toMatchObject({
      mode: 'subscription',
      line_items: [{ price: 'price_monthly_test', quantity: 1 }],
      customer: 'cus_1',
      metadata: { app: 'shepetal', plan: 'monthly', user_id: String(user.id) },
      subscription_data: { metadata: { app: 'shepetal', user_id: String(user.id) } },
    });
    expect(params.payment_intent_data).toBeUndefined();
    expect(params).toMatchObject({ automatic_tax: { enabled: true }, consent_collection: { terms_of_service: 'required' } });
    expect((params.custom_text?.terms_of_service_acceptance as { message: string } | undefined)?.message).toMatch(/subscription to start right away.*cancel anytime/i);
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
    expect(await portalUrl({ ...user, stripe_customer_id: 'cus_1' }, SITE_URL)).toBe('https://billing.stripe.com/p/session/1');
    expect(create).toHaveBeenCalledWith({ customer: 'cus_1', configuration: 'bpc_test', return_url: `${SITE_URL}/account` });
  });
});

describe('plan settings: cancel, resume, the portal', () => {
  const subscribed = async (over = {}) => {
    retrieving(sub(over));
    await send(event(sub(over), 'customer.subscription.updated'));
    return fresh();
  };

  it('cancels at period end: stored at once, still active until then, no further charge', async () => {
    const u = await subscribed();
    const update = vi.spyOn(getStripe().subscriptions, 'update').mockResolvedValue(sub({ cancel_at_period_end: true }) as never);
    expect(await setCancelAtPeriodEnd(u, true)).toBe(true);
    expect(update).toHaveBeenCalledWith('sub_1', { cancel_at_period_end: true });
    expect(await license()).toMatchObject({ status: 'active', plan: 'subscription', renews: false });
    expect(await setCancelAtPeriodEnd(await fresh(), true)).toBe(false);
    // And back: resume before the period ends.
    update.mockResolvedValue(sub() as never);
    expect(await setCancelAtPeriodEnd(await fresh(), false)).toBe(true);
    expect(update).toHaveBeenLastCalledWith('sub_1', { cancel_at_period_end: false });
    expect((await license()).renews).toBe(true);
    expect(await setCancelAtPeriodEnd(await fresh(), false)).toBe(false);
  });

  it('gives the next charge of a renewing subscription, and none once cancelled', async () => {
    const u = await subscribed({ items: { data: [{ price: { unit_amount: 99, currency: 'usd' } }] } });
    expect(await nextCharge(u)).toEqual({ amount: 99, currency: 'usd', at: u.current_period_end });
    expect(await nextCharge({ ...u, cancel_at_period_end: 1 })).toBeNull();
    expect(await nextCharge({ ...u, sub_status: 'past_due' })).toBeNull();
    expect(await nextCharge(user)).toBeNull();
    // A row without the amount yet reads it from Stripe once.
    retrieving(sub({ items: { data: [{ price: { unit_amount: 99, currency: 'usd' } }] } }));
    expect(await nextCharge({ ...u, sub_amount: null, sub_currency: null })).toMatchObject({ amount: 99, currency: 'usd' });
  });

  it('refuses to cancel without a subscription', async () => {
    const update = vi.spyOn(getStripe().subscriptions, 'update');
    expect(await setCancelAtPeriodEnd(user, true)).toBe(false);
    expect(update).not.toHaveBeenCalled();
  });

  it('opens the portal on the cancel confirmation of the subscription', async () => {
    const u = { ...(await subscribed()), stripe_customer_id: 'cus_1' };
    const create = vi.spyOn(getStripe().billingPortal.sessions, 'create').mockResolvedValue({ url: 'https://billing.stripe.com/p/flow' } as never);
    expect(await portalUrl(u, 'https://s', 'cancel')).toBe('https://billing.stripe.com/p/flow');
    expect(create).toHaveBeenCalledWith({
      customer: 'cus_1',
      configuration: 'bpc_test',
      return_url: 'https://s/account',
      flow_data: {
        type: 'subscription_cancel',
        subscription_cancel: { subscription: 'sub_1' },
        after_completion: { type: 'redirect', redirect: { return_url: 'https://s/account?cancelled=1' } },
      },
    });
    expect(await portalUrl({ ...user, stripe_customer_id: 'cus_1' }, 'https://s', 'cancel')).toBeNull();
  });

  it('stores what a renewal charges, for the settings', async () => {
    await subscribed({ items: { data: [{ price: { unit_amount: 99, currency: 'usd' } }] } });
    expect(await fresh()).toMatchObject({ sub_amount: 99, sub_currency: 'usd' });
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

  it('takes an event again when its claim never finished (the Worker was cut off), but not while it runs', async () => {
    const payload = event(sub(), 'customer.subscription.updated', 'evt_cut');
    const at = (ms: number) => new Date(Date.now() - ms).toISOString();
    await db().prepare("INSERT INTO stripe_events (id, type, received_at) VALUES ('evt_cut', 'customer.subscription.updated', ?1)").bind(at(1000)).run();
    expect((await send(payload)).status).toBe(409);
    await db().prepare("UPDATE stripe_events SET received_at = ?1 WHERE id = 'evt_cut'").bind(at(5 * 60_000)).run();
    retrieving(sub());
    expect(await (await send(payload)).json()).toEqual({ received: true });
    expect((await license()).status).toBe('active');
    expect((await db().prepare("SELECT done FROM stripe_events WHERE id = 'evt_cut'").first())?.done).toBe(1);
    expect(await (await send(payload)).json()).toEqual({ received: true, duplicate: true });
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
