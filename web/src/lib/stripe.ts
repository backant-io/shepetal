import type Stripe from 'stripe';
import {
  activate,
  applySubscription,
  recordConsent,
  liveSubscription,
  renewingSubscription,
  revokeLifetime,
  TERMINAL,
  setCustomer,
  userByCustomer,
  userById,
  type Subscription,
  type User,
} from './account';
import { db } from './db';
import { SITE_URL } from './site';
import { StripeApiError, stripeApi, verifyWebhook } from './stripe-api';

let stripe: Stripe | undefined;

/**
 * backant's Stripe account (same STRIPE_SECRET_KEY as backant.io), over fetch (lib/stripe-api.ts, API 2025-02-24.acacia):
 * the SDK's setup alone took more CPU than a request gets on the Workers Free plan.
 */
export function getStripe(): Stripe {
  const key = process.env.STRIPE_SECRET_KEY;
  if (!key) throw new Error('STRIPE_SECRET_KEY is not set');
  // web/e2e only: STRIPE_API_BASE points a test key at the harness's fake Stripe API.
  const fake = key.startsWith('sk_test_') && process.env.STRIPE_API_BASE ? new URL(process.env.STRIPE_API_BASE).origin : null;
  stripe ??= stripeApi(key, fake ?? 'https://api.stripe.com');
  return stripe;
}

/**
 * shepetal's look on Stripe Checkout (the wordmark, the icon as favicon, the site's colours), set per session, so the
 * shared account's branding stays backant's. Receipts and invoices keep the account's branding: BackAnt, Inc. is the
 * seller. branding_settings needs API 2025-09-30.clover on the create call; stripe@17's types predate it.
 */
export const CHECKOUT_API_VERSION = '2025-09-30.clover';
export const CHECKOUT_BRANDING = {
  display_name: 'shepetal',
  logo: { type: 'url', url: `${SITE_URL}/press/shepetal-wordmark-ink.png` },
  icon: { type: 'url', url: `${SITE_URL}/icon-512.png` },
  background_color: '#E6E4DE',
  button_color: '#161512',
  font_family: 'inter',
  border_style: 'rounded',
};

// backant's Stripe account also sends backant.io's own checkouts to every webhook
// endpoint, so shepetal's sessions and subscriptions carry this tag and the webhook ignores the rest.
const APP = 'shepetal';

/** The two plans a buyer picks from. */
export type CheckoutPlan = 'lifetime' | 'monthly';
export const PLANS: readonly CheckoutPlan[] = ['lifetime', 'monthly'];

/**
 * The prices are found by lookup key, so test and live mode need no price IDs in config.
 * web/scripts/stripe-setup.mjs creates them: $23.99 one-time and $0.99 a month.
 * STRIPE_PRICE_LIFETIME / STRIPE_PRICE_MONTHLY override the lookup.
 */
export const LOOKUP_KEYS: Record<CheckoutPlan, string> = { lifetime: 'shepetal_lifetime', monthly: 'shepetal_monthly' };
const priceIds = new Map<CheckoutPlan, string>();

export async function priceFor(plan: CheckoutPlan): Promise<string> {
  const override = process.env[plan === 'lifetime' ? 'STRIPE_PRICE_LIFETIME' : 'STRIPE_PRICE_MONTHLY'];
  if (override) return override;
  const cached = priceIds.get(plan);
  if (cached) return cached;
  const { data } = await getStripe().prices.list({ lookup_keys: [LOOKUP_KEYS[plan]], active: true, limit: 1 });
  if (!data[0]) throw new Error(`no active Stripe price with lookup_key ${LOOKUP_KEYS[plan]}: run web/scripts/stripe-setup.mjs`);
  priceIds.set(plan, data[0].id);
  return data[0].id;
}

/**
 * The user's own Stripe customer, created at their first checkout. Every checkout reuses it, so
 * the PRODUCTHUNT code (first_time_transaction) works once per user and the Billing Portal finds the subscription.
 */
export async function customerFor(user: User): Promise<string> {
  if (user.stripe_customer_id) return user.stripe_customer_id;
  const c = await getStripe().customers.create(
    // The footer goes on every invoice of this customer (each subscription month): the confirmation, on a durable
    // medium, of the consent given at checkout (EU digital-content rules).
    { email: user.email, metadata: { app: APP, user_id: String(user.id) }, invoice_settings: { footer: CONFIRMATION } },
    // Two clicks at once make one customer. The trial start makes the key unique to this row, even across databases.
    { idempotencyKey: `shepetal-customer-${user.id}-${user.trial_started_at}` },
  );
  await setCustomer(user.id, c.id);
  return (await userById(user.id))?.stripe_customer_id ?? c.id;
}

/**
 * EU consumer law for digital content: the buyer asks for delivery right away and acknowledges that this ends the
 * 14-day right of withdrawal. Stripe's required consent checkbox (consent_collection.terms_of_service) carries this
 * text instead of its default, so the purchase cannot complete without it; the session records the consent, and the
 * webhook stores when it was given.
 */
export const consentText = (plan: CheckoutPlan, origin: string) =>
  plan === 'lifetime'
    ? `I want shepetal delivered right away, and I understand that this ends my 14-day right of withdrawal. I accept the [Terms](${origin}/terms) and the [Refund policy](${origin}/refunds).`
    : `I want my subscription to start right away, and I understand that this ends my 14-day right of withdrawal. I can cancel anytime. I accept the [Terms](${origin}/terms) and the [Refund policy](${origin}/refunds).`;

/** On receipts and invoices: the confirmation of that consent, on a durable medium. */
export const CONFIRMATION = 'Delivered right away at your request. You acknowledged that this ends the 14-day right of withdrawal.';

/**
 * Stripe Tax code of both products: txcd_10202000, Downloadable Software, personal use (shepetal is downloaded and runs
 * on the Mac, and its buyers are consumers). Set on the products by stripe-setup.mjs, never left to the account default.
 */
export const TAX_CODES: Record<CheckoutPlan, string> = { lifetime: 'txcd_10202000', monthly: 'txcd_10202000' };

/** A code the buyer typed that cannot be used: the reason, for the API's 400. */
export class CodeError extends Error {
  constructor(
    readonly code: 'code_lifetime_only' | 'invalid_code' | 'code_not_applicable',
    message: string,
  ) {
    super(message);
  }
}

/**
 * The promotion code for `code`, if it is shepetal's: its coupon carries metadata app=shepetal (stripe-setup.mjs
 * makes PRODUCTHUNT so). The Stripe account is shared with backant.io, whose codes (some 100% off, none limited to
 * a product) must never reach shepetal, so Checkout never shows Stripe's own code field (allow_promotion_codes).
 */
async function shepetalPromotionCode(code: string): Promise<string> {
  const { data } = await getStripe().promotionCodes.list({ code: code.trim(), active: true, limit: 10 });
  const ours = data.find((p) => p.coupon.metadata?.app === APP);
  if (!ours) throw new CodeError('invalid_code', 'This code is not valid.');
  return ours.id;
}

/** Open Checkout sessions of this customer are expired before a new one opens, so a second tab cannot pay twice. */
async function expireOpenSessions(customer: string): Promise<void> {
  for await (const old of getStripe().checkout.sessions.list({ customer, status: 'open', limit: 100 })) {
    if (old.metadata?.app === APP) await getStripe().checkout.sessions.expire(old.id).catch(() => {});
  }
}

/**
 * POST /api/checkout: a Checkout session for the plan. `base` is the site origin.
 * lifetime: mode payment, $23.99 once. monthly: mode subscription, $0.99 a month.
 * `code` (the PRODUCTHUNT code) applies to the lifetime plan only, and only a shepetal code is accepted. Stripe then
 * checks its own rules (the lifetime product only, first transaction, expiry) when the session is created.
 */
export async function checkoutUrl(user: User, base: string, plan: CheckoutPlan = 'lifetime', code?: string): Promise<string> {
  if (code && plan !== 'lifetime') throw new CodeError('code_lifetime_only', 'The code works on the one-time price only.');
  const promotion = code ? await shepetalPromotionCode(code) : null;
  const price = await priceFor(plan);
  const customer = await customerFor(user);
  await expireOpenSessions(customer);
  const tag = { app: APP, user_id: String(user.id) };
  const common = {
    line_items: [{ price, quantity: 1 }],
    customer,
    ...(promotion && { discounts: [{ promotion_code: promotion }] }),
    metadata: { ...tag, plan },
    success_url: `${base}/account?purchased=1`,
    cancel_url: `${base}/account`,
    // Stripe Tax: the price includes VAT for EU consumers (tax_behavior inclusive, stripe-setup.mjs); Stripe works
    // out the tax from the billing address, and a business can give its VAT ID (reverse charge).
    automatic_tax: { enabled: true },
    customer_update: { address: 'auto' as const, name: 'auto' as const },
    tax_id_collection: { enabled: true },
    consent_collection: { terms_of_service: 'required' as const },
    custom_text: {
      terms_of_service_acceptance: { message: consentText(plan, base) },
      submit: { message: plan === 'lifetime' ? 'shepetal is yours right after you pay.' : 'Your subscription starts right after you pay.' },
    },
    branding_settings: CHECKOUT_BRANDING,
  };
  let session: Stripe.Checkout.Session;
  try {
    session = await getStripe().checkout.sessions.create(
      plan === 'lifetime'
        ? {
            ...common,
            mode: 'payment',
            client_reference_id: String(user.id),
            // The description is on the receipt email: the purchase and the consent, on a durable medium.
            // The card statement reads "BACKANT, I* SHEPETAL" (the account's prefix, then this suffix).
            payment_intent_data: { metadata: tag, description: `shepetal lifetime license. ${CONFIRMATION}`, statement_descriptor_suffix: 'SHEPETAL' },
          }
        : // No client_reference_id: backant.io's webhook (same Stripe account) acts on every subscription checkout
          // that has one, as its own client id. The user id travels in metadata instead.
          { ...common, mode: 'subscription', subscription_data: { metadata: tag } },
      { apiVersion: CHECKOUT_API_VERSION },
    );
  } catch (e) {
    // Stripe refuses a code that has ended or was used up, or meets a customer who has paid before.
    if (promotion && e instanceof StripeApiError && e.type === 'invalid_request_error') {
      throw new CodeError('code_not_applicable', /prior transactions|first.time/i.test(e.message) ? 'This code is for a first purchase.' : 'This code has ended.');
    }
    throw e;
  }
  if (!session.url) throw new Error('Stripe returned a checkout session without a url');
  return session.url;
}

let portalConfig: string | undefined;

/** The Billing Portal configuration web/scripts/stripe-setup.mjs made (metadata app=shepetal): cancel at period end, card, invoices. */
async function portalConfiguration(): Promise<string> {
  if (process.env.STRIPE_PORTAL_CONFIG) return process.env.STRIPE_PORTAL_CONFIG;
  if (portalConfig) return portalConfig;
  for await (const c of getStripe().billingPortal.configurations.list({ active: true, limit: 100 })) {
    if (c.metadata?.app === APP) return (portalConfig = c.id);
  }
  throw new Error('no Billing Portal configuration with metadata app=shepetal: run web/scripts/stripe-setup.mjs');
}

/**
 * POST /api/billing/portal: the Stripe Billing Portal for the user's customer (card, invoices, cancel), or null if
 * they never checked out. flow 'cancel' opens straight on the cancel confirmation of their subscription.
 */
export async function portalUrl(user: User, base: string, flow?: 'cancel'): Promise<string | null> {
  if (!user.stripe_customer_id) return null;
  const sub = flow === 'cancel' ? renewingSubscription(user) : null;
  if (flow === 'cancel' && !sub) return null;
  const session = await getStripe().billingPortal.sessions.create({
    customer: user.stripe_customer_id,
    configuration: await portalConfiguration(),
    return_url: `${base}/account`,
    ...(sub && {
      flow_data: {
        type: 'subscription_cancel' as const,
        subscription_cancel: { subscription: sub },
        after_completion: { type: 'redirect' as const, redirect: { return_url: `${base}/account?cancelled=1` } },
      },
    }),
  });
  return session.url;
}

/**
 * POST /api/billing/cancel and /api/billing/resume: the subscription stops renewing (it keeps working until its
 * period end, with no further charge), or renews again. Stored right away from Stripe's answer, so the settings show
 * it before the webhook arrives. False if the user has no subscription in that state.
 */
export async function setCancelAtPeriodEnd(user: User, cancel: boolean): Promise<boolean> {
  const id = cancel ? renewingSubscription(user) : user.sub_id && user.cancel_at_period_end && user.sub_status === 'active' ? user.sub_id : null;
  if (!id) return false;
  const s = await getStripe().subscriptions.update(id, { cancel_at_period_end: cancel });
  await applySubscription(user.id, snapshot(s));
  return true;
}

/**
 * The next charge of a renewing subscription, for the settings card: amount in the smallest currency unit (99),
 * currency ("usd") and when (ISO). Null when nothing renews (lifetime, trial, cancelled, past due, ended). From the
 * account row; the amount is read from Stripe once if the row has none yet.
 */
export async function nextCharge(user: User): Promise<{ amount: number; currency: string; at: string } | null> {
  const id = renewingSubscription(user);
  const at = user.current_period_end;
  if (!id || !at || user.sub_status !== 'active' && user.sub_status !== 'trialing') return null;
  if (user.sub_amount != null && user.sub_currency) return { amount: user.sub_amount, currency: user.sub_currency, at };
  const snap = snapshot(await getStripe().subscriptions.retrieve(id));
  await applySubscription(user.id, snap);
  return snap.amount != null && snap.currency ? { amount: snap.amount, currency: snap.currency, at } : null;
}

/**
 * Switch to lifetime: the lifetime license was paid, so the subscription ends now. No further charge: no
 * proration, no final invoice, and an unpaid renewal invoice is voided. Safe to run twice (Stripe retries the webhook).
 */
async function endSubscriptionForLifetime(subId: string): Promise<void> {
  const ended = await endSubscription(subId, false);
  const userId = Number(ended.metadata?.user_id);
  if (userId) await applySubscription(userId, snapshot(ended));
}

/**
 * Ends a subscription now: no proration, no final invoice, open invoices voided. `refund`: it should never have
 * existed (a second subscription, or one for an owner of the lifetime license), so what it was paid is refunded too.
 * Safe to run twice. Returns the subscription as it is after.
 */
async function endSubscription(subId: string, refund: boolean): Promise<Stripe.Subscription> {
  const stripe = getStripe();
  const s = await stripe.subscriptions.retrieve(subId);
  if (s.status !== 'canceled' && s.status !== 'incomplete_expired') {
    await stripe.subscriptions.cancel(subId, { invoice_now: false, prorate: false }, { idempotencyKey: `shepetal-end-${subId}` });
  }
  for await (const inv of stripe.invoices.list({ subscription: subId, status: 'open', limit: 100 })) {
    await stripe.invoices.voidInvoice(inv.id);
  }
  if (refund) {
    for await (const inv of stripe.invoices.list({ subscription: subId, status: 'paid', limit: 100 })) {
      const pi = idOf((inv as unknown as { payment_intent?: string | { id: string } | null }).payment_intent);
      if (pi && inv.amount_paid > 0) await refundOnce(pi, 'duplicate_subscription');
    }
  }
  return stripe.subscriptions.retrieve(subId);
}

/** Refunds a payment in full, once (the idempotency key), tagged so the charge.refunded handler leaves the license alone. */
async function refundOnce(paymentIntent: string, why: string): Promise<void> {
  try {
    await getStripe().refunds.create(
      { payment_intent: paymentIntent, metadata: { app: APP, reason: why } },
      { idempotencyKey: `shepetal-refund-${paymentIntent}` },
    );
  } catch (e) {
    // Run again after Stripe forgot the idempotency key (24 h): the refund is already there, nothing to do.
    if (e instanceof StripeApiError && e.code === 'charge_already_refunded') return;
    throw e;
  }
}

/** The subscription fields the account stores. Reads the item's period on API versions that moved it there. */
function snapshot(s: Stripe.Subscription): Subscription {
  const item = s.items?.data?.[0] as
    | { current_period_start?: number; current_period_end?: number; price?: { unit_amount?: number | null; currency?: string } }
    | undefined;
  return {
    amount: item?.price?.unit_amount ?? null,
    currency: item?.price?.currency ?? null,
    id: s.id,
    status: s.status,
    current_period_start: s.current_period_start ?? item?.current_period_start ?? 0,
    current_period_end: s.current_period_end ?? item?.current_period_end ?? 0,
    cancel_at_period_end: s.cancel_at_period_end,
    ended_at: s.ended_at ?? null,
  };
}

const idOf = (x: string | { id: string } | null | undefined) => (typeof x === 'string' ? x : (x?.id ?? null));

/**
 * Reads the subscription fresh from Stripe and stores it, if it is shepetal's. `unpaidInvoice`: an
 * invoice.payment_failed whose invoice is still open, so the subscription counts as past_due even
 * if Stripe has not moved its status yet.
 */
async function syncSubscription(id: string, unpaidInvoice = false): Promise<void> {
  const s = await getStripe().subscriptions.retrieve(id);
  if (s.metadata?.app !== APP) return;
  const customer = idOf(s.customer);
  const userId = Number(s.metadata.user_id) || (customer && (await userByCustomer(customer))?.id);
  if (!userId) return console.error(`stripe webhook: no user for subscription ${s.id}`);
  if (customer) await setCustomer(userId, customer);
  const user = await userById(userId);
  if (!user) return console.error(`stripe webhook: no user ${userId} for subscription ${s.id}`);
  if (!TERMINAL.has(s.status)) {
    // A subscription that should not exist is ended and refunded: one for an owner of the lifetime license (a
    // monthly checkout paid in another tab), or a second one beside a live subscription (the later one goes).
    if (user.status === 'active') {
      // Made after the lifetime purchase: it should never have been paid, so it is refunded. Made before: the switch
      // to lifetime (its cancel failed earlier and runs now), so its past months stay paid.
      const after = !user.purchased_at || s.created * 1000 > Date.parse(user.purchased_at);
      console.error(`stripe webhook: ${s.id} for lifetime user ${userId}: ended${after ? ' and refunded' : ''}`);
      await applySubscription(userId, snapshot(await endSubscription(s.id, after)));
      return;
    }
    if (user.sub_id && user.sub_id !== s.id) {
      const other = await getStripe().subscriptions.retrieve(user.sub_id);
      if (!TERMINAL.has(other.status)) {
        // Keep the one in good standing (paid up), else the older one.
        const good = (x: Stripe.Subscription) => (x.status === 'active' || x.status === 'trialing' ? 0 : 1);
        const [keep, extra] = good(other) !== good(s) ? (good(other) < good(s) ? [other, s] : [s, other])
          : other.created <= s.created ? [other, s] : [s, other];
        console.error(`stripe webhook: two subscriptions for user ${userId}: ${extra.id} ended and refunded, ${keep.id} kept`);
        // The later one is refunded; an older one in arrears just stops (its months were used, its open invoice is voided).
        await endSubscription(extra.id, extra.created >= keep.created);
        await applySubscription(userId, snapshot(keep));
        return;
      }
    }
  }
  const snap = snapshot(s);
  if (unpaidInvoice && snap.status === 'active') snap.status = 'past_due';
  if (!(await applySubscription(userId, snap))) console.error(`stripe webhook: subscription ${s.id} not stored for user ${userId}`);
}

/** The subscription an invoice bills: `subscription` before API version 2025-03-31, `parent.subscription_details` after. */
function invoiceSubscription(inv: Record<string, any>): { id: string | null; ours: boolean | null } {
  const parent = inv.parent?.subscription_details;
  // The subscription's metadata as copied onto the invoice, when Stripe sent it: null means unknown, so fetch it.
  const meta = inv.subscription_details?.metadata ?? parent?.metadata;
  return { id: idOf(inv.subscription) ?? idOf(parent?.subscription), ours: meta ? meta.app === APP : null };
}

async function handleEvent(event: Stripe.Event): Promise<void> {
  switch (event.type) {
    // async_payment_succeeded: a delayed payment method (e.g. bank debit) completed with payment_status 'unpaid'.
    case 'checkout.session.completed':
    case 'checkout.session.async_payment_succeeded': {
      const s = event.data.object;
      if (s.metadata?.app !== APP) return;
      const userId = Number(s.client_reference_id ?? s.metadata.user_id);
      const customer = idOf(s.customer);
      if (customer && userId) await setCustomer(userId, customer);
      // The consent to delivery right away (and so the end of the withdrawal right), kept with the account.
      if (userId && s.consent?.terms_of_service === 'accepted') await recordConsent(userId, event.created);
      if (s.mode === 'subscription') {
        const sub = idOf(s.subscription);
        if (sub) await syncSubscription(sub);
        return;
      }
      // no_payment_required: a code that takes the whole price off.
      if (s.payment_status !== 'paid' && s.payment_status !== 'no_payment_required') return;
      const pi = idOf(s.payment_intent);
      const before = await userById(userId);
      if (!before) return console.error(`stripe webhook: no user ${s.client_reference_id} for paid session ${s.id}`);
      // Bought twice (two tabs): the license is the first payment's; this one is refunded. A purchase from before
      // the plans has no PaymentIntent stored: this one fills it in.
      if (before.status === 'active' && pi && before.lifetime_payment_intent && before.lifetime_payment_intent !== pi) {
        console.error(`stripe webhook: second lifetime payment ${pi} for user ${userId}: refunded`);
        return refundOnce(pi, 'duplicate_lifetime');
      }
      await activate(userId, pi);
      // Two payments handled at the same moment: whichever did not get stored is refunded.
      const stored = (await userById(userId))?.lifetime_payment_intent;
      if (pi && stored && stored !== pi) {
        console.error(`stripe webhook: concurrent lifetime payment ${pi} for user ${userId}: refunded`);
        return refundOnce(pi, 'duplicate_lifetime');
      }
      // Switched to lifetime while subscribed: the subscription ends now, with no further charge.
      const user = await userById(userId);
      const live = user && liveSubscription(user);
      if (live) await endSubscriptionForLifetime(live);
      return;
    }
    case 'customer.subscription.created':
    case 'customer.subscription.updated':
    case 'customer.subscription.deleted': {
      const s = event.data.object;
      if (s.metadata?.app !== APP) return;
      return syncSubscription(s.id);
    }
    // A refund of the lifetime payment (in full) ends the license. Refunds this code made itself are of other payments.
    case 'charge.refunded': {
      const c = event.data.object;
      const pi = idOf(c.payment_intent);
      if (!pi || !c.refunded) return;
      if (await revokeLifetime(pi)) console.error(`stripe webhook: lifetime payment ${pi} refunded: license ended`);
      return;
    }
    case 'invoice.paid':
    case 'invoice.payment_failed': {
      const inv = event.data.object as unknown as Record<string, any>;
      const sub = invoiceSubscription(inv);
      if (!sub.id || sub.ours === false) return;
      let unpaid = false;
      if (event.type === 'invoice.payment_failed') unpaid = (await getStripe().invoices.retrieve(inv.id)).status === 'open';
      return syncSubscription(sub.id, unpaid);
    }
  }
}

/** The events the webhook endpoint subscribes to (web/scripts/stripe-setup.mjs prints them, API.md lists them). */
export const WEBHOOK_EVENTS = [
  'checkout.session.completed',
  'checkout.session.async_payment_succeeded',
  'customer.subscription.updated',
  'customer.subscription.deleted',
  'invoice.paid',
  'invoice.payment_failed',
  'charge.refunded',
] as const;
const HANDLED = new Set<string>([...WEBHOOK_EVENTS, 'customer.subscription.created']);
/** A claim older than this that never finished is taken again by Stripe's next retry. */
const CLAIM_MS = 120_000;

/**
 * POST /api/stripe/webhook. 400 unless the Stripe-Signature matches STRIPE_WEBHOOK_SECRET.
 * Each event id is handled once: it is claimed in stripe_events before it runs and marked done after. A failure
 * releases it (500); a delivery while it runs gets 409; a claim that never finished (the Worker was cut off) is
 * taken again after 2 minutes. Stripe retries all of these, and every handler is safe to run again.
 */
export async function handleWebhook(body: string, signature: string | null): Promise<Response> {
  const secret = process.env.STRIPE_WEBHOOK_SECRET;
  if (!secret) throw new Error('STRIPE_WEBHOOK_SECRET is not set');
  let event: Stripe.Event;
  try {
    event = await verifyWebhook(body, signature, secret);
  } catch {
    return Response.json({ error: 'invalid signature' }, { status: 400 });
  }
  if (!HANDLED.has(event.type)) return Response.json({ received: true });
  // Claim the id: a new row, or an old claim that never finished (the Worker was cut off). A finished event, or one
  // running right now, is not claimed.
  const now = Date.now();
  const claim = await db()
    .prepare(
      `INSERT INTO stripe_events (id, type, received_at) VALUES (?1, ?2, ?3)
       ON CONFLICT (id) DO UPDATE SET received_at = excluded.received_at WHERE stripe_events.done = 0 AND stripe_events.received_at < ?4`,
    )
    .bind(event.id, event.type, new Date(now).toISOString(), new Date(now - CLAIM_MS).toISOString())
    .run();
  if (claim.meta.changes !== 1) {
    const row = await db().prepare('SELECT done FROM stripe_events WHERE id = ?1').bind(event.id).first<{ done: number }>();
    if (row?.done) return Response.json({ received: true, duplicate: true });
    return Response.json({ error: 'in progress, retry' }, { status: 409 });
  }
  try {
    await handleEvent(event);
  } catch (e) {
    await db().prepare('DELETE FROM stripe_events WHERE id = ?1').bind(event.id).run();
    console.error(`stripe webhook: ${event.type} ${event.id} failed: ${e instanceof Error ? e.message : e}`);
    return Response.json({ error: 'failed, retry' }, { status: 500 });
  }
  await db().prepare('UPDATE stripe_events SET done = 1 WHERE id = ?1').bind(event.id).run();
  // Stripe stops retrying an event after 3 days, so older ids are never needed again.
  await db()
    .prepare('DELETE FROM stripe_events WHERE received_at < ?1')
    .bind(new Date(Date.now() - 30 * 86_400_000).toISOString())
    .run();
  return Response.json({ received: true });
}
