import { db } from './db';

export const TRIAL_DAYS = 30;
const DAY_MS = 86_400_000;

export type User = {
  id: number;
  email: string;
  trial_started_at: string;
  status: 'trial' | 'active';
  purchased_at: string | null;
};

/** Body of GET /api/license (see API.md). */
export type License = {
  status: 'trial' | 'active' | 'expired';
  trial_ends_at: string | null;
  email: string;
};

/** The license a user row grants at `now`. 'active' never expires. */
export function licenseOf(user: User, now = Date.now()): License {
  if (user.status === 'active') return { status: 'active', trial_ends_at: null, email: user.email };
  const ends = Date.parse(user.trial_started_at) + TRIAL_DAYS * DAY_MS;
  return {
    status: now < ends ? 'trial' : 'expired',
    trial_ends_at: new Date(ends).toISOString(),
    email: user.email,
  };
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

/** A paid purchase: the user is 'active' forever. Idempotent (Stripe retries webhooks). False if no such user. */
export async function activate(userId: number, now = Date.now()): Promise<boolean> {
  const r = await db()
    .prepare("UPDATE users SET status = 'active', purchased_at = COALESCE(purchased_at, ?2) WHERE id = ?1")
    .bind(userId, new Date(now).toISOString())
    .run();
  return r.meta.changes === 1;
}
