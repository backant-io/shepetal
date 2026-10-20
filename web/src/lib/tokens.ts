import type { User } from './account';
import { db } from './db';

/** SHA-256 hex. Tokens and app login codes are only ever stored as this hash. */
export async function sha256(s: string): Promise<string> {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** 32 random bytes, base64url. Used for access tokens and app login codes. */
export function randomSecret(): string {
  const b = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** The token in `Authorization: Bearer <token>`, or null. */
export const bearer = (req: Request) => req.headers.get('authorization')?.match(/^Bearer\s+(\S+)$/i)?.[1] ?? null;

/** A new app access token for `email` (an existing users row). Returns the raw token; only its hash is stored. */
export async function createToken(email: string): Promise<string> {
  const token = randomSecret();
  await db().prepare('INSERT INTO tokens (hash, email) VALUES (?1, ?2)').bind(await sha256(token), email).run();
  return token;
}

/** A token dies after this many days without use (API.md). Each use starts the count again. */
export const TOKEN_IDLE_DAYS = 90;

/** The user of an unrevoked token used in the last 90 days, or null. Counts as a use. */
export async function userForToken(token: string, now = Date.now()): Promise<User | null> {
  const iso = (ms: number) => new Date(ms).toISOString();
  const live = await db()
    .prepare(
      'UPDATE tokens SET last_used_at = ?2 WHERE hash = ?1 AND revoked_at IS NULL AND COALESCE(last_used_at, created_at) > ?3 RETURNING email',
    )
    .bind(await sha256(token), iso(now), iso(now - TOKEN_IDLE_DAYS * 86_400_000))
    .first<{ email: string }>();
  return live && db().prepare('SELECT * FROM users WHERE email = ?1').bind(live.email).first<User>();
}

export async function revokeToken(token: string, now = Date.now()): Promise<void> {
  await db()
    .prepare('UPDATE tokens SET revoked_at = ?2 WHERE hash = ?1 AND revoked_at IS NULL')
    .bind(await sha256(token), new Date(now).toISOString())
    .run();
}
