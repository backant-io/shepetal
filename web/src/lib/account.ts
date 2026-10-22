import { db } from './db';

export const TRIAL_DAYS = 30;
const DAY_MS = 86_400_000;

/** What a user pays for. 'trial' until a checkout completes. */
export type Plan = 'trial' | 'lifetime' | 'subscription';

export type User = {
  id: number;
  email: string;
  trial_started_at: string;
  /** 'active' is the lifetime license. A subscriber stays 'trial' here: the sub_* columns carry the subscription. */
  status: 'trial' | 'active';
  purchased_at: string | null;
  plan?: 'lifetime' | 'subscription' | null;
  stripe_customer_id?: string | null;
  sub_id?: string | null;
  sub_status?: string | null;
  current_period_end?: string | null;
  cancel_at_period_end?: number | null;
  paid_through?: string | null;
  sub_amount?: number | null;
  sub_currency?: string | null;
  lifetime_payment_intent?: string | null;
  withdrawal_waived_at?: string | null;
};

/** Body of GET /api/license (see API.md). */
export type License = {
  /** Whether shepetal works now: 'active' for a lifetime license or a paid-up subscription. */
  status: 'trial' | 'active' | 'expired';
  plan: Plan;
  trial_ends_at: string | null;
  /** Subscription: the end of the last paid period (it works until then). Null for lifetime and the trial. */
  paid_through: string | null;
  /** Subscription: it renews at paid_through. False once cancelled (it ends at paid_through). */
  renews: boolean;
  /** Subscription: the last renewal could not be charged. The card needs updating in the Billing Portal. */
  payment_failed: boolean;
  email: string;
};

// Stripe keeps retrying a past_due or unpaid subscription, so it still renews once the card works.
const RENEWING = new Set(['active', 'trialing', 'past_due', 'unpaid']);
const FAILED = new Set(['past_due', 'unpaid']);

function trialOf(user: User, now: number): Pick<License, 'status' | 'trial_ends_at'> {
  const ends = Date.parse(user.trial_started_at) + TRIAL_DAYS * DAY_MS;
  return { status: now < ends ? 'trial' : 'expired', trial_ends_at: new Date(ends).toISOString() };
}

/**
 * The license a user row grants at `now`. A lifetime license never expires. A subscription is
 * 'active' until paid_through; after that the trial dates decide, as if it never existed.
 */
export function licenseOf(user: User, now = Date.now()): License {
  const none = { paid_through: null, renews: false, payment_failed: false };
  if (user.status === 'active') {
    return { status: 'active', plan: 'lifetime', trial_ends_at: null, ...none, email: user.email };
  }
  if (user.plan === 'subscription') {
    const through = user.paid_through ?? null;
    const sub = {
      plan: 'subscription' as const,
      paid_through: through,
      renews: RENEWING.has(user.sub_status ?? '') && !user.cancel_at_period_end,
      payment_failed: FAILED.has(user.sub_status ?? ''),
      email: user.email,
    };
    if (through && now < Date.parse(through)) return { status: 'active', trial_ends_at: null, ...sub };
    return { ...trialOf(user, now), ...sub };
  }
  return { ...trialOf(user, now), plan: 'trial', ...none, email: user.email };
}

/**
 * The user for `email`, created on first sight, which starts the trial.
 * Emails are stored lowercased: use the returned row's email for other tables.
 */
export async function upsertUser(email: string): Promise<User> {
  const user = await db()
    .prepare(
      'INSERT INTO users (email) VALUES (?1) ON CONFLICT (email) DO UPDATE SET email = excluded.email RETURNING *',
    )
    .bind(email.trim().toLowerCase())
    .first<User>();
  if (!user) throw new Error('users upsert returned no row');
  return user;
}

export async function getLicense(email: string): Promise<License> {
  return licenseOf(await upsertUser(email));
}

export async function userById(id: number): Promise<User | null> {
  return db().prepare('SELECT * FROM users WHERE id = ?1').bind(id).first<User>();
}

export async function userByCustomer(customer: string): Promise<User | null> {
  return db().prepare('SELECT * FROM users WHERE stripe_customer_id = ?1').bind(customer).first<User>();
}

/** Remembers the user's Stripe customer. Only fills an empty slot: a user keeps their first customer. */
export async function setCustomer(userId: number, customer: string): Promise<void> {
  await db()
    .prepare('UPDATE users SET stripe_customer_id = ?2 WHERE id = ?1 AND stripe_customer_id IS NULL')
    .bind(userId, customer)
    .run();
}

/**
 * A paid lifetime purchase: the user is 'active' forever. Idempotent (Stripe retries webhooks). False if no such user.
 * `paymentIntent` is the payment that bought it (kept from the first purchase).
 */
export async function activate(userId: number, paymentIntent: string | null = null, now = Date.now()): Promise<boolean> {
  const r = await db()
    .prepare(
      `UPDATE users SET status = 'active', plan = 'lifetime', purchased_at = COALESCE(purchased_at, ?2),
         lifetime_payment_intent = COALESCE(lifetime_payment_intent, ?3) WHERE id = ?1`,
    )
    .bind(userId, new Date(now).toISOString(), paymentIntent)
    .run();
  return r.meta.changes === 1;
}

/**
 * When the buyer last consented at checkout to delivery right away, acknowledging the end of the 14-day withdrawal
 * right (EU digital-content rules). `at` is the Stripe event time, in Unix seconds.
 */
export async function recordConsent(userId: number, at: number): Promise<void> {
  await db()
    .prepare('UPDATE users SET withdrawal_waived_at = ?2 WHERE id = ?1 AND (withdrawal_waived_at IS NULL OR withdrawal_waived_at < ?2)')
    .bind(userId, new Date(at * 1000).toISOString())
    .run();
}

/** The lifetime payment was refunded: the license ends (back to the trial dates, or a running subscription). */
export async function revokeLifetime(paymentIntent: string): Promise<boolean> {
  const r = await db()
    .prepare(
      `UPDATE users SET status = 'trial', purchased_at = NULL, lifetime_payment_intent = NULL,
         plan = CASE WHEN sub_id IS NOT NULL AND sub_status NOT IN ('canceled', 'incomplete', 'incomplete_expired') THEN 'subscription' ELSE NULL END
       WHERE lifetime_payment_intent = ?1 AND status = 'active'`,
    )
    .bind(paymentIntent)
    .run();
  return r.meta.changes === 1;
}

/** The fields of a Stripe subscription the account needs. Times are Unix seconds, as Stripe sends them. */
export type Subscription = {
  id: string;
  status: string;
  current_period_start: number;
  current_period_end: number;
  cancel_at_period_end: boolean;
  ended_at: number | null;
  /** What a renewal charges (the price's unit_amount and currency), when known. */
  amount?: number | null;
  currency?: string | null;
};

export const TERMINAL = new Set(['canceled', 'incomplete', 'incomplete_expired']);
const iso = (s: number) => new Date(s * 1000).toISOString();

/**
 * The end of the paid time, from the subscription as Stripe has it now and what was stored before.
 * - active or trialing: the current period is paid, up to its end.
 * - past_due, unpaid or paused: the renewal was not paid, so the paid time ended where this period began.
 * - canceled: it ended at ended_at, never later than the time already paid for.
 * - incomplete: the first payment has not gone through: nothing more is paid.
 */
export function paidThrough(sub: Subscription, stored: string | null): string | null {
  switch (sub.status) {
    case 'active':
    case 'trialing':
      return iso(sub.current_period_end);
    case 'past_due':
    case 'unpaid':
    case 'paused':
      return iso(sub.current_period_start);
    case 'canceled': {
      const ended = iso(sub.ended_at ?? sub.current_period_end);
      return stored && Date.parse(stored) < Date.parse(ended) ? stored : ended;
    }
    default:
      return stored;
  }
}

/**
 * Stores a subscription as Stripe has it now (the webhook reads it fresh, so the order events
 * arrive in does not matter). A user has one subscription: an ended one never replaces another.
 * False if no such user, or if the snapshot was ignored.
 */
export async function applySubscription(userId: number, sub: Subscription): Promise<boolean> {
  const user = await userById(userId);
  if (!user) return false;
  if (user.sub_id && user.sub_id !== sub.id && TERMINAL.has(sub.status)) return false;
  const stored = user.sub_id === sub.id ? (user.paid_through ?? null) : null;
  const r = await db()
    .prepare(
      `UPDATE users SET plan = CASE WHEN plan = 'lifetime' OR ?3 IN ('incomplete', 'incomplete_expired') THEN plan ELSE 'subscription' END,
         sub_id = ?2, sub_status = ?3, current_period_end = ?4, cancel_at_period_end = ?5, paid_through = ?6,
         sub_amount = COALESCE(?7, sub_amount), sub_currency = COALESCE(?8, sub_currency)
       WHERE id = ?1`,
    )
    .bind(userId, sub.id, sub.status, iso(sub.current_period_end), sub.cancel_at_period_end ? 1 : 0, paidThrough(sub, stored),
      sub.amount ?? null, sub.currency ?? null)
    .run();
  return r.meta.changes === 1;
}

/** A subscription that has not ended yet (renewing, cancelled to its period end, or past due), or null. */
export function liveSubscription(user: User): string | null {
  return user.sub_id && !TERMINAL.has(user.sub_status ?? '') ? user.sub_id : null;
}

/** A subscription that will charge again, so it can be cancelled to its period end. */
export function renewingSubscription(user: User): string | null {
  return user.sub_id && RENEWING.has(user.sub_status ?? '') && !user.cancel_at_period_end ? user.sub_id : null;
}

/** Body of GET /api/account/plan (API.md): what the plan settings on /account show and offer. */
export type PlanSettings = {
  plan: Plan;
  /** Whether shepetal works now, as in GET /api/license. */
  status: License['status'];
  email: string;
  /** While the free trial runs. */
  trial: { ends_at: string; days_left: number } | null;
  lifetime: { purchased_at: string | null } | null;
  subscription: {
    /** active: renews; cancels_at_period_end: cancelled, works until ends_at; past_due: a renewal failed; ended. */
    status: 'active' | 'cancels_at_period_end' | 'past_due' | 'ended';
    /** The end of the paid time (GET /api/license's paid_through). */
    paid_through: string | null;
    /** The next charge, for an active subscription; null once cancelled, past due or ended. */
    next_billing_date: string | null;
    /** When it stops: the period end once cancelled, or when it ended. */
    ends_at: string | null;
    /** What each renewal charges, in the smallest currency unit (99 = $0.99), and how to show it. */
    amount: number | null;
    currency: string | null;
    amount_display: string | null;
    interval: 'month';
  } | null;
  /** What the settings can offer now. */
  actions: { cancel: boolean; resume: boolean; switch_to_lifetime: boolean; portal: boolean; choose_plan: boolean };
};

const money = (amount: number | null | undefined, currency: string | null | undefined) =>
  amount == null || !currency ? null : new Intl.NumberFormat('en-US', { style: 'currency', currency: currency.toUpperCase() }).format(amount / 100);

export function planSettings(user: User, now = Date.now()): PlanSettings {
  const l = licenseOf(user, now);
  const trial =
    l.status === 'trial' && l.trial_ends_at
      ? { ends_at: l.trial_ends_at, days_left: Math.max(0, Math.ceil((Date.parse(l.trial_ends_at) - now) / DAY_MS)) }
      : null;
  let subscription: PlanSettings['subscription'] = null;
  if (l.plan === 'subscription') {
    const status = l.payment_failed ? 'past_due' : l.status !== 'active' ? 'ended' : l.renews ? 'active' : 'cancels_at_period_end';
    subscription = {
      status,
      paid_through: l.paid_through,
      next_billing_date: status === 'active' ? l.paid_through : null,
      ends_at: status === 'cancels_at_period_end' || status === 'ended' ? l.paid_through : null,
      amount: user.sub_amount ?? null,
      currency: user.sub_currency ?? null,
      amount_display: money(user.sub_amount, user.sub_currency),
      interval: 'month',
    };
  }
  const live = subscription && subscription.status !== 'ended';
  return {
    plan: l.plan,
    status: l.status,
    email: l.email,
    trial,
    lifetime: l.plan === 'lifetime' ? { purchased_at: user.purchased_at } : null,
    subscription,
    actions: {
      cancel: subscription?.status === 'active' || subscription?.status === 'past_due',
      resume: subscription?.status === 'cancels_at_period_end',
      switch_to_lifetime: !!live,
      portal: !!user.stripe_customer_id,
      choose_plan: l.plan === 'trial' || subscription?.status === 'ended',
    },
  };
}
