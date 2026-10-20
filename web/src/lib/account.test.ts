import { expect, it } from 'vitest';
import { licenseOf, type User } from './account';

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

it('gives a free trial of exactly 30 days from the first sign-in', () => {
  expect(licenseOf(user(), t0 + 30 * DAY - 1)).toEqual({
    status: 'trial',
    trial_ends_at: '2026-01-31T00:00:00.000Z',
    email: 'a@example.com',
  });
  expect(licenseOf(user(), t0 + 30 * DAY).status).toBe('expired');
});

it('keeps a purchase active forever, long after the trial ended', () => {
  expect(licenseOf(user({ status: 'active' }), t0 + 3650 * DAY)).toEqual({
    status: 'active',
    trial_ends_at: null,
    email: 'a@example.com',
  });
});
