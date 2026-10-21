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

/** A paid lifetime purchase: the user is 'active' forever. Idempotent (Stripe retries webhooks). False if no such user. */
export async function activate(userId: number, now = Date.now()): Promise<boolean> {
  const r = await db()
    .prepare(
      "UPDATE users SET status = 'active', plan = 'lifetime', purchased_at = COALESCE(purchased_at, ?2) WHERE id = ?1",
    )
    .bind(userId, new Date(now).toISOString())
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
};

const TERMINAL = new Set(['canceled', 'incomplete', 'incomplete_expired']);
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
      `UPDATE users SET plan = CASE WHEN plan = 'lifetime' THEN plan ELSE 'subscription' END,
         sub_id = ?2, sub_status = ?3, current_period_end = ?4, cancel_at_period_end = ?5, paid_through = ?6
       WHERE id = ?1`,
    )
    .bind(userId, sub.id, sub.status, iso(sub.current_period_end), sub.cancel_at_period_end ? 1 : 0, paidThrough(sub, stored))
    .run();
  return r.meta.changes === 1;
}

/** A subscription that will charge again: an owner of the lifetime license should not keep paying for it. */
export function renewingSubscription(user: User): string | null {
  return user.sub_id && RENEWING.has(user.sub_status ?? '') && !user.cancel_at_period_end ? user.sub_id : null;
}
