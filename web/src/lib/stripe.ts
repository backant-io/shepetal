import Stripe from 'stripe';
import {
  activate,
  applySubscription,
  liveSubscription,
  renewingSubscription,
  setCustomer,
  userByCustomer,
  userById,
  type Subscription,
  type User,
} from './account';
import { db } from './db';

let stripe: Stripe | undefined;

/**
 * backant's Stripe account (same STRIPE_SECRET_KEY as backant.io). Uses the fetch
 * client because this runs on a Worker. Verify webhooks with
 * stripe.webhooks.constructEventAsync(body, sig, STRIPE_WEBHOOK_SECRET, undefined, Stripe.createSubtleCryptoProvider()).
 */
export function getStripe(): Stripe {
  const key = process.env.STRIPE_SECRET_KEY;
  if (!key) throw new Error('STRIPE_SECRET_KEY is not set');
  // web/e2e only: STRIPE_API_BASE points a test key at the harness's fake Stripe API.
  const fake = key.startsWith('sk_test_') && process.env.STRIPE_API_BASE ? new URL(process.env.STRIPE_API_BASE) : null;
  stripe ??= new Stripe(key, {
    apiVersion: '2025-02-24.acacia',
    httpClient: Stripe.createFetchHttpClient(),
    ...(fake && { protocol: 'http', host: fake.hostname, port: fake.port }),
  });
  return stripe;
}

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
    { email: user.email, metadata: { app: APP, user_id: String(user.id) } },
    // Two clicks at once make one customer. The trial start makes the key unique to this row, even across databases.
    { idempotencyKey: `shepetal-customer-${user.id}-${user.trial_started_at}` },
  );
  await setCustomer(user.id, c.id);
  return (await userById(user.id))?.stripe_customer_id ?? c.id;
}

/**
 * POST /api/checkout: a Checkout session for the plan. `base` is the site origin.
 * lifetime: mode payment, $23.99 once. monthly: mode subscription, $0.99 a month.
 * Both accept promotion codes; the PRODUCTHUNT coupon applies to the lifetime product only, so Stripe refuses it on the monthly plan.
 */
export async function checkoutUrl(user: User, base: string, plan: CheckoutPlan = 'lifetime'): Promise<string> {
  const price = await priceFor(plan);
  const customer = await customerFor(user);
  const tag = { app: APP, user_id: String(user.id) };
  const common = {
    line_items: [{ price, quantity: 1 }],
    customer,
    allow_promotion_codes: true,
    metadata: { ...tag, plan },
    success_url: `${base}/account?purchased=1`,
    cancel_url: `${base}/account`,
  };
  const session = await getStripe().checkout.sessions.create(
    plan === 'lifetime'
      ? { ...common, mode: 'payment', client_reference_id: String(user.id), payment_intent_data: { metadata: tag } }
      : // No client_reference_id: backant.io's webhook (same Stripe account) acts on every subscription checkout
        // that has one, as its own client id. The user id travels in metadata instead.
        { ...common, mode: 'subscription', subscription_data: { metadata: tag } },
  );
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
 * Switch to lifetime: the lifetime license was paid, so the subscription ends now. No further charge: no
 * proration, no final invoice, and an unpaid renewal invoice is voided. Safe to run twice (Stripe retries the webhook).
 */
async function endSubscriptionForLifetime(subId: string): Promise<void> {
  const stripe = getStripe();
  const s = await stripe.subscriptions.retrieve(subId);
  if (s.status !== 'canceled' && s.status !== 'incomplete_expired') {
    await stripe.subscriptions.cancel(subId, { invoice_now: false, prorate: false }, { idempotencyKey: `shepetal-lifetime-${subId}` });
  }
  for await (const inv of stripe.invoices.list({ subscription: subId, status: 'open', limit: 100 })) {
    await stripe.invoices.voidInvoice(inv.id);
  }
  const ended = await stripe.subscriptions.retrieve(subId);
  const userId = Number(ended.metadata?.user_id);
  if (userId) await applySubscription(userId, snapshot(ended));
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
  const snap = snapshot(s);
  if (unpaidInvoice && snap.status === 'active') snap.status = 'past_due';
  if (customer) await setCustomer(userId, customer);
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
      if (s.mode === 'subscription') {
        const sub = idOf(s.subscription);
        if (sub) await syncSubscription(sub);
        return;
      }
      // no_payment_required: a code that takes the whole price off.
      if (s.payment_status !== 'paid' && s.payment_status !== 'no_payment_required') return;
      if (!(await activate(userId))) return console.error(`stripe webhook: no user ${s.client_reference_id} for paid session ${s.id}`);
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
] as const;
const HANDLED = new Set<string>([...WEBHOOK_EVENTS, 'customer.subscription.created']);

/**
 * POST /api/stripe/webhook. 400 unless the Stripe-Signature matches STRIPE_WEBHOOK_SECRET.
 * Each event id is handled once: it is claimed in stripe_events before it runs, and released again
 * if it fails (500), so Stripe's retry runs it then.
 */
export async function handleWebhook(body: string, signature: string | null): Promise<Response> {
  const secret = process.env.STRIPE_WEBHOOK_SECRET;
  if (!secret) throw new Error('STRIPE_WEBHOOK_SECRET is not set');
  let event: Stripe.Event;
  try {
    event = await getStripe().webhooks.constructEventAsync(
      body,
      signature ?? '',
      secret,
      undefined,
      Stripe.createSubtleCryptoProvider(),
    );
  } catch {
    return Response.json({ error: 'invalid signature' }, { status: 400 });
  }
  if (!HANDLED.has(event.type)) return Response.json({ received: true });
  const claim = await db()
    .prepare('INSERT INTO stripe_events (id, type) VALUES (?1, ?2) ON CONFLICT (id) DO NOTHING')
    .bind(event.id, event.type)
    .run();
  if (claim.meta.changes !== 1) return Response.json({ received: true, duplicate: true });
  try {
    await handleEvent(event);
  } catch (e) {
    await db().prepare('DELETE FROM stripe_events WHERE id = ?1').bind(event.id).run();
    console.error(`stripe webhook: ${event.type} ${event.id} failed: ${e instanceof Error ? e.message : e}`);
    return Response.json({ error: 'failed, retry' }, { status: 500 });
  }
  // Stripe stops retrying an event after 3 days, so older ids are never needed again.
  await db()
    .prepare('DELETE FROM stripe_events WHERE received_at < ?1')
    .bind(new Date(Date.now() - 30 * 86_400_000).toISOString())
    .run();
  return Response.json({ received: true });
}
