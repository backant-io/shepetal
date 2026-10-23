import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { upsertUser } from './account';
import { googleCallback, signInPost, siteUrl } from './auth';
import { b64url, unseal } from './session';
import { db, useTestDb } from './test-db';

// No trial emails are sent: /login has no box, and the native sign-in records no opt-in, even for a posted field.
vi.mock('./db', () => import('./test-db'));
useTestDb();

const SECRET = 'auth-no-trial-emails-secret';
const CLIENT = 'client-123.apps.googleusercontent.com';
Object.assign(process.env, { AUTH_SECRET: SECRET, GOOGLE_CLIENT_ID: CLIENT, GOOGLE_CLIENT_SECRET: 'google-client-secret' });

const nowS = () => Math.floor(Date.now() / 1000);
const idToken = (email: string) => {
  const claims = { iss: 'https://accounts.google.com', aud: CLIENT, azp: CLIENT, sub: '1', email, email_verified: true, iat: nowS(), exp: nowS() + 3600 };
  return `eyJhbGciOiJSUzI1NiJ9.${b64url(new TextEncoder().encode(JSON.stringify(claims)))}.c2ln`;
};
const jar = (res: Response) =>
  res.headers.getSetCookie().filter((c) => !/Max-Age=0\b/.test(c)).map((c) => c.split(';')[0]).join('; ');
const optIn = (email: string) => db().prepare('SELECT trial_emails_at FROM users WHERE email = ?1').bind(email).first<{ trial_emails_at: string | null }>();

/** The /login form posted with `body`, then Google bringing `email` back. */
async function signIn(email: string, body: string) {
  vi.stubGlobal('fetch', vi.fn(async () => Response.json({ access_token: 'ya29.x', id_token: idToken(email) })));
  const go = await signInPost(
    new Request(`${siteUrl()}/api/auth/signin/google?callbackUrl=%2Faccount`, {
      method: 'POST',
      headers: { origin: siteUrl(), 'content-type': 'application/x-www-form-urlencoded' },
      body,
    }),
  );
  const state = new URL(go.headers.get('location')!).searchParams.get('state')!;
  const done = await googleCallback(new Request(`${siteUrl()}/api/auth/callback/google?code=x&state=${state}`, { headers: { cookie: jar(go) } }));
  expect(done.headers.get('location')).toBe(`${siteUrl()}/account`);
  return go;
}

beforeEach(() => vi.useRealTimers());
afterEach(() => vi.unstubAllGlobals());

describe('the native sign-in records no trial emails opt-in', () => {
  it('signs in a new user without an opt-in, with or without a posted trial_emails=yes', async () => {
    const go = await signIn('new@example.com', 'trial_emails=yes');
    expect(await optIn('new@example.com')).toEqual({ trial_emails_at: null });
    const cookie = go.headers.getSetCookie().find((c) => c.startsWith('__Host-shepetal-oauth='))!;
    expect(await unseal(SECRET, 'shepetal-oauth', cookie.split(';')[0].split('=')[1])).not.toHaveProperty('t');
    await signIn('quiet@example.com', '');
    expect(await optIn('quiet@example.com')).toEqual({ trial_emails_at: null });
  });

  it('leaves an earlier opt-in and an unsubscribe as they were', async () => {
    const { id } = await upsertUser('kept@example.com');
    await db().prepare("UPDATE users SET trial_emails_at = '2026-10-01T00:00:00.000Z' WHERE id = ?1").bind(id).run();
    await db().prepare('INSERT INTO email_unsubscribes (user_id) VALUES (?1)').bind(id).run();
    await signIn('kept@example.com', 'trial_emails=yes');
    expect(await optIn('kept@example.com')).toEqual({ trial_emails_at: '2026-10-01T00:00:00.000Z' });
    expect(await db().prepare('SELECT 1 FROM email_unsubscribes WHERE user_id = ?1').bind(id).first()).not.toBeNull();
  });
});
