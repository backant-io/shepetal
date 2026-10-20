import { expect, it, vi } from 'vitest';
import { licenseOf, upsertUser } from './account';
import { db } from './db';
import { useTestDb } from './test-db';
import { bearer, createToken, revokeToken, sha256, userForToken } from './tokens';

vi.mock('./db', () => import('./test-db'));
useTestDb();

const DAY = 86_400_000;

it('hashes with SHA-256 (hex)', async () => {
  expect(await sha256('abc')).toBe('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
});

// A leaked tokens table must not hand out working tokens.
it('stores only the SHA-256 of a token, never the token', async () => {
  const { email } = await upsertUser('a@example.com');
  const token = await createToken(email);
  const { results } = await db().prepare('SELECT * FROM tokens').all();
  expect(results.map((r) => r.hash)).toEqual([await sha256(token)]);
  expect(JSON.stringify(results)).not.toContain(token);
});

it('makes random, unguessable tokens', async () => {
  const { email } = await upsertUser('a@example.com');
  const [a, b] = [await createToken(email), await createToken(email)];
  expect(a).not.toBe(b);
  expect(a).toMatch(/^[A-Za-z0-9_-]{43}$/); // 32 bytes
});

it('revokes one token without signing out the user elsewhere', async () => {
  const { email } = await upsertUser('a@example.com');
  const [mac, other] = [await createToken(email), await createToken(email)];
  expect((await userForToken(mac))?.email).toBe(email);
  await revokeToken(mac);
  expect(await userForToken(mac)).toBeNull();
  expect((await userForToken(other))?.email).toBe(email);
});

it('knows no user for an unknown token', async () => {
  await upsertUser('a@example.com');
  expect(await userForToken('not-a-token')).toBeNull();
});

// GET /api/license: what the app sees for its token (null is the 401).
it('reports trial, expired and active license status for a token', async () => {
  const { email } = await upsertUser('a@example.com');
  const token = await createToken(email);
  const status = async (now = Date.now()) => licenseOf((await userForToken(token))!, now).status;

  expect(await status()).toBe('trial');
  expect(await status(Date.now() + 31 * DAY)).toBe('expired');
  await db().prepare("UPDATE users SET status = 'active' WHERE email = ?1").bind(email).run();
  expect(await status(Date.now() + 3650 * DAY)).toBe('active');
});

it('reads the bearer token from the Authorization header', () => {
  const req = (h?: string) => new Request('https://x', { headers: h ? { authorization: h } : {} });
  expect(bearer(req('Bearer abc_-1'))).toBe('abc_-1');
  expect(bearer(req('Basic abc'))).toBeNull();
  expect(bearer(req())).toBeNull();
});
