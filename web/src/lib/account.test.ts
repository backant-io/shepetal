import { expect, it, vi } from 'vitest';
import { licenseOf, upsertUser, type User } from './account';
import { useTestDb } from './test-db';

vi.mock('./db', () => import('./test-db'));
useTestDb();

const DAY = 86_400_000;
const start = '2026-01-01T00:00:00.000Z';
const t0 = Date.parse(start);
const user = (over: Partial<User> = {}): User => ({
  id: 1,
  email: 'a@example.com',
  trial_started_at: start,
  status: 'trial',
  purchased_at: null,
  ...over,
});

// The product promise: 30 free days, counted from the first sign-in. Day 30 is the first day without it.
it.each([
  [0, 'trial'],
  [29, 'trial'],
  [30, 'expired'],
  [31, 'expired'],
])('on day %i after the first sign-in the license is %s', (day, status) => {
  expect(licenseOf(user(), t0 + day * DAY)).toEqual({
    status,
    trial_ends_at: '2026-01-31T00:00:00.000Z',
    email: 'a@example.com',
  });
});

it('gives a free trial of exactly 30 days from the first sign-in', () => {
  expect(licenseOf(user(), t0 + 30 * DAY - 1).status).toBe('trial');
  expect(licenseOf(user(), t0 + 30 * DAY).status).toBe('expired');
});

it('keeps a purchase active forever, long after the trial ended', () => {
  expect(licenseOf(user({ status: 'active' }), t0 + 3650 * DAY)).toEqual({
    status: 'active',
    trial_ends_at: null,
    email: 'a@example.com',
  });
});

// Signing in again (web or another device) must never hand out a fresh trial.
it('starts the trial at the first sign-in and never restarts it', async () => {
  const first = await upsertUser(' New@Example.com ');
  await new Promise((r) => setTimeout(r, 20));
  const again = await upsertUser('new@example.com');
  expect(first.email).toBe('new@example.com');
  expect(again.id).toBe(first.id);
  expect(again.trial_started_at).toBe(first.trial_started_at);
  expect(Math.abs(Date.parse(first.trial_started_at) - Date.now())).toBeLessThan(5_000);
});
