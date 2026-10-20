import { expect, it, vi } from 'vitest';
import { upsertUser } from './account';
import { db } from './db';
import { approveDevice, EXPIRES_IN, INTERVAL, pollDevice, startDevice } from './device';
import { useTestDb } from './test-db';
import { userForToken } from './tokens';

vi.mock('./db', () => import('./test-db'));
useTestDb();

const BASE = 'https://shepetal.backant.io';
const T = Date.parse('2026-01-01T00:00:00.000Z');
const S = 1000;
const start = () => startDevice(BASE, T);

it('starts with the response shape in API.md', async () => {
  const d = await start();
  expect(d).toEqual({
    device_code: expect.stringMatching(/^[A-Za-z0-9_-]{43}$/),
    user_code: expect.stringMatching(/^[B-DF-HJ-NP-TV-XZ]{4}-[B-DF-HJ-NP-TV-XZ]{4}$/),
    verification_uri_complete: `https://shepetal.backant.io/device?code=${d.user_code}`,
    expires_in: EXPIRES_IN,
    interval: INTERVAL,
  });
  // device_code is a secret like the access token: only its hash is stored
  expect(JSON.stringify((await db().prepare('SELECT * FROM device_codes').all()).results)).not.toContain(d.device_code);
});

it('is authorization_pending until the user decides', async () => {
  const d = await start();
  expect(await pollDevice(d.device_code, T)).toEqual({ error: 'authorization_pending' });
  expect(await pollDevice(d.device_code, T + INTERVAL * S)).toEqual({ error: 'authorization_pending' });
});

// Rate limit: polling faster than `interval` gets slow_down, at the interval it is answered again.
it('answers slow_down to a poll sooner than the interval', async () => {
  const d = await start();
  await pollDevice(d.device_code, T);
  expect(await pollDevice(d.device_code, T + INTERVAL * S - 1)).toEqual({ error: 'slow_down' });
  expect(await pollDevice(d.device_code, T + 2 * INTERVAL * S - 1)).toEqual({ error: 'authorization_pending' });
});

it('gives the app a token for the approving user, exactly once', async () => {
  const d = await start();
  const { email } = await upsertUser('a@example.com');
  expect(await approveDevice(d.user_code.toLowerCase().replace('-', ' '), email, true, T)).toBe(true);

  const r = await pollDevice(d.device_code, T);
  expect(r).toEqual({ access_token: expect.any(String), email: 'a@example.com' });
  if (!('access_token' in r)) throw new Error('no token');
  expect((await userForToken(r.access_token))?.email).toBe('a@example.com');

  // the same device code never mints a second token, nor can it be approved again
  expect(await pollDevice(d.device_code, T + INTERVAL * S)).toEqual({ error: 'expired_token' });
  expect(await approveDevice(d.user_code, email, true, T)).toBe(false);
  expect((await db().prepare('SELECT COUNT(*) AS n FROM tokens').first())?.n).toBe(1);
});

it('is access_denied when the user denies', async () => {
  const d = await start();
  const { email } = await upsertUser('a@example.com');
  expect(await approveDevice(d.user_code, email, false, T)).toBe(true);
  expect(await pollDevice(d.device_code, T)).toEqual({ error: 'access_denied' });
});

it('is expired_token after expires_in, and an expired code cannot be approved', async () => {
  const d = await start();
  const { email } = await upsertUser('a@example.com');
  const end = T + EXPIRES_IN * S;
  expect(await pollDevice(d.device_code, end - 1)).toEqual({ error: 'authorization_pending' });
  expect(await approveDevice(d.user_code, email, true, end)).toBe(false);
  expect(await pollDevice(d.device_code, end)).toEqual({ error: 'expired_token' });
});

it('is expired_token for an unknown device code', async () => {
  await start();
  expect(await pollDevice('nope', T)).toEqual({ error: 'expired_token' });
});
