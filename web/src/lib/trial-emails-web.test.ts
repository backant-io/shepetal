import { beforeEach, describe, expect, it, vi } from 'vitest';
import { upsertUser } from './account';
import { db, useTestDb } from './test-db';

// The website sign-in: the box on /login is posted before Google, and the user row exists only in next-auth's signIn
// callback after it. A cookie carries the tick across; these tests run both ends against a cookie jar.
const jar = vi.hoisted(() => new Map<string, { value: string; opts?: Record<string, unknown> }>());
vi.mock('next/headers', () => ({
  cookies: async () => ({
    get: (name: string) => (jar.has(name) ? { name, value: jar.get(name)!.value } : undefined),
    set: (name: string, value: string, opts?: Record<string, unknown>) => void jar.set(name, { value, opts }),
    delete: (name: string) => void jar.delete(name),
  }),
}));
vi.mock('next-auth', () => ({ default: () => ({ handlers: {}, auth: async () => null, signIn: async () => undefined, signOut: async () => undefined }) }));
vi.mock('./db', () => import('./test-db'));
useTestDb();

const { trialEmailsFromCookie } = await import('./auth');
const { keepTrialEmailsChoice } = await import('@/components/SignInButton');
const optIn = (email: string) => db().prepare('SELECT trial_emails_at FROM users WHERE email = ?1').bind(email).first<{ trial_emails_at: string | null }>();
const form = (fields: Record<string, string>) => {
  const f = new FormData();
  for (const [k, v] of Object.entries(fields)) f.append(k, v);
  return f;
};

beforeEach(() => jar.clear());

describe('the trial emails box on /login', () => {
  it('ticked: the opt-in is recorded once Google brings the user back, and the cookie is dropped', async () => {
    await keepTrialEmailsChoice(form({ trial_emails: 'yes' }));
    expect(jar.get('trial-emails')).toMatchObject({ value: 'yes', opts: { maxAge: 600, httpOnly: true, sameSite: 'lax' } });
    await upsertUser('new@example.com'); // the callback creates the user first
    await trialEmailsFromCookie('new@example.com');
    expect((await optIn('new@example.com'))?.trial_emails_at).toMatch(/^\d{4}-\d\d-\d\dT/);
    expect(jar.has('trial-emails')).toBe(false);
  });

  it('unticked: nothing is recorded, and an earlier tick in this browser is dropped', async () => {
    jar.set('trial-emails', { value: 'yes' });
    await keepTrialEmailsChoice(form({}));
    expect(jar.has('trial-emails')).toBe(false);
    await upsertUser('quiet@example.com');
    await trialEmailsFromCookie('quiet@example.com');
    expect(await optIn('quiet@example.com')).toEqual({ trial_emails_at: null });
  });
});
