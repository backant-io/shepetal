import Stripe from 'stripe';
import { beforeEach, expect, it, vi } from 'vitest';
import { upsertUser, type User } from './account';
import { db } from './db';
import { handleWebhook } from './stripe';
import { useTestDb } from './test-db';

vi.mock('./db', () => import('./test-db'));
useTestDb();

const SECRET = 'whsec_test_secret';
process.env.STRIPE_SECRET_KEY = 'sk_test_unused';
process.env.STRIPE_WEBHOOK_SECRET = SECRET;

const stripe = new Stripe('sk_test_unused');
let user: User;
beforeEach(async () => {
  user = await upsertUser('a@example.com');
});

const event = (session: object, type = 'checkout.session.completed') =>
  JSON.stringify({ id: 'evt_1', object: 'event', type, data: { object: { id: 'cs_1', object: 'checkout.session', ...session } } });
const paid = () => event({ client_reference_id: String(user.id), metadata: { app: 'shepetal' }, payment_status: 'paid' });
const sign = (payload: string, secret = SECRET) => stripe.webhooks.generateTestHeaderString({ payload, secret });
const status = async () => (await db().prepare('SELECT status FROM users WHERE id = ?1').bind(user.id).first())?.status;

it('activates the user forever on a paid, signed checkout.session.completed', async () => {
  const res = await handleWebhook(paid(), sign(paid()));
  expect(res.status).toBe(200);
  expect(await status()).toBe('active');
});

// Anyone can POST to the webhook URL: without Stripe's signature nothing may change.
it('rejects a bad, missing or tampered signature and changes nothing', async () => {
  expect((await handleWebhook(paid(), sign(paid(), 'whsec_someone_else'))).status).toBe(400);
  expect((await handleWebhook(paid(), null)).status).toBe(400);
  const other = event({ client_reference_id: '999', metadata: { app: 'shepetal' }, payment_status: 'paid' });
  expect((await handleWebhook(paid(), sign(other))).status).toBe(400);
  expect(await status()).toBe('trial');
});

// The Stripe account is backant's: its own checkouts reach this endpoint too.
it('ignores checkouts that are not shepetal purchases', async () => {
  const backant = event({ client_reference_id: String(user.id), metadata: {}, payment_status: 'paid' });
  expect((await handleWebhook(backant, sign(backant))).status).toBe(200);
  expect(await status()).toBe('trial');
});

it('waits for a delayed payment to succeed before activating', async () => {
  const s = { client_reference_id: String(user.id), metadata: { app: 'shepetal' } };
  const unpaid = event({ ...s, payment_status: 'unpaid' });
  await handleWebhook(unpaid, sign(unpaid));
  expect(await status()).toBe('trial');
  const later = event({ ...s, payment_status: 'paid' }, 'checkout.session.async_payment_succeeded');
  await handleWebhook(later, sign(later));
  expect(await status()).toBe('active');
});
