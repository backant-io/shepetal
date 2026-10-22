import { createHmac } from 'node:crypto';
import Stripe from 'stripe';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { formEncode, StripeApiError, stripeApi, verifyWebhook } from './stripe-api';

// The Stripe calls go over fetch instead of the SDK (CPU on the Workers Free plan), so they must say exactly what the
// SDK said, and the webhook must be refused exactly when the SDK would have refused it (or stricter).

afterEach(() => vi.unstubAllGlobals());

describe('form encoding, as the SDK sends it', () => {
  it('nests objects, indexes arrays, writes booleans and keeps an empty string (how Stripe unsets a field)', () => {
    const sdkLike = formEncode({
      line_items: [{ price: 'price_1', quantity: 1 }],
      metadata: { app: 'shepetal', user_id: '7' },
      automatic_tax: { enabled: true },
      cancel_at: '',
      skipped: undefined,
      success_url: 'https://shepetal.app/account?purchased=1',
      custom_text: { submit: { message: 'Yours & right away.' } },
    });
    expect(sdkLike).toBe(
      'line_items[0][price]=price_1&line_items[0][quantity]=1&metadata[app]=shepetal&metadata[user_id]=7&automatic_tax[enabled]=true&cancel_at=' +
        '&success_url=https%3A%2F%2Fshepetal.app%2Faccount%3Fpurchased%3D1&custom_text[submit][message]=Yours%20%26%20right%20away.',
    );
    expect(Object.fromEntries(new URLSearchParams(sdkLike))).toMatchObject({ 'line_items[0][price]': 'price_1', cancel_at: '', 'custom_text[submit][message]': 'Yours & right away.' });
  });
});

describe('the fetch client', () => {
  const calls: { url: string; init: RequestInit }[] = [];
  const answer = (...bodies: [number, object][]) => {
    calls.length = 0;
    vi.stubGlobal('fetch', async (url: string, init: RequestInit) => {
      calls.push({ url, init });
      const [status, body] = bodies.shift()!;
      return Response.json(body, { status });
    });
  };
  const s = stripeApi('sk_test_x', 'http://127.0.0.1:1');

  it('POSTs a form with the key, the pinned API version (or the call’s) and the idempotency key', async () => {
    answer([200, { id: 'cs_1', url: 'https://checkout.stripe.com/x' }]);
    const r = await s.checkout.sessions.create({ mode: 'payment', metadata: { app: 'shepetal' } }, { apiVersion: '2025-09-30.clover', idempotencyKey: 'k1' });
    expect(r).toMatchObject({ id: 'cs_1' });
    expect(calls[0].url).toBe('http://127.0.0.1:1/v1/checkout/sessions');
    expect(calls[0].init).toMatchObject({ method: 'POST', body: 'mode=payment&metadata[app]=shepetal' });
    expect(calls[0].init.headers).toEqual({
      authorization: 'Bearer sk_test_x',
      'stripe-version': '2025-09-30.clover',
      'idempotency-key': 'k1',
      'content-type': 'application/x-www-form-urlencoded',
    });
    answer([200, { id: 'sub_1' }]);
    await s.subscriptions.update('sub_1', { cancel_at_period_end: false });
    expect(calls[0].init.headers).toMatchObject({ 'stripe-version': '2025-02-24.acacia' });
    expect(calls[0].init.body).toBe('cancel_at_period_end=false');
  });

  it('sends GET and DELETE parameters in the query', async () => {
    answer([200, { id: 'sub_1', status: 'canceled' }]);
    await s.subscriptions.cancel('sub_1', { invoice_now: false, prorate: false }, { idempotencyKey: 'shepetal-end-sub_1' });
    expect([calls[0].url, calls[0].init.method, calls[0].init.body]).toEqual(['http://127.0.0.1:1/v1/subscriptions/sub_1?invoice_now=false&prorate=false', 'DELETE', undefined]);
  });

  it('a list is its first page when awaited, and every item, page after page, when iterated', async () => {
    answer([200, { data: [{ id: 'a' }], has_more: false }]);
    expect((await s.prices.list({ lookup_keys: ['k'], limit: 1 })).data).toEqual([{ id: 'a' }]);
    expect(calls[0].url).toBe('http://127.0.0.1:1/v1/prices?lookup_keys[0]=k&limit=1');
    answer([200, { data: [{ id: 'a' }, { id: 'b' }], has_more: true }], [200, { data: [{ id: 'c' }], has_more: false }]);
    const seen: string[] = [];
    for await (const x of s.invoices.list({ subscription: 'sub_1', status: 'open', limit: 2 })) seen.push(x.id);
    expect(seen).toEqual(['a', 'b', 'c']);
    expect(calls[1].url).toBe('http://127.0.0.1:1/v1/invoices?subscription=sub_1&status=open&limit=2&starting_after=b');
  });

  it('throws Stripe’s error type, code and message, and nothing of the request', async () => {
    answer([400, { error: { type: 'invalid_request_error', code: 'charge_already_refunded', message: 'Charge has already been refunded.' } }]);
    const e = await s.refunds.create({ payment_intent: 'pi_1' }).catch((x: unknown) => x);
    expect(e).toBeInstanceOf(StripeApiError);
    expect(e).toMatchObject({ type: 'invalid_request_error', code: 'charge_already_refunded', message: 'Charge has already been refunded.', statusCode: 400 });
    expect(JSON.stringify(e) + String(e)).not.toContain('sk_test_x');
  });
});

describe('the webhook signature', () => {
  const secret = 'whsec_test_0123456789';
  const body = JSON.stringify({ id: 'evt_1', type: 'checkout.session.completed', data: { object: { name: 'Zoë Åström 🔑' } } });
  const now = Date.now();
  /** The header the real Stripe SDK makes. */
  const sdk = (timestamp = Math.floor(now / 1000), payload = body, key = secret) =>
    new Stripe('sk_test_x').webhooks.generateTestHeaderString({ payload, secret: key, timestamp });

  it('accepts what the Stripe SDK signs (non-ASCII body included), and any of several v1', async () => {
    expect(await verifyWebhook(body, sdk(), secret, now)).toMatchObject({ id: 'evt_1' });
    const t = Math.floor(now / 1000);
    const v1 = createHmac('sha256', secret).update(`${t}.${body}`, 'utf8').digest('hex');
    expect(await verifyWebhook(body, `t=${t},v1=${'0'.repeat(64)},v1=${v1},v0=x`, secret, now)).toMatchObject({ id: 'evt_1' });
  });

  it('refuses another secret, a changed body, or a malformed or missing header', async () => {
    const t = Math.floor(now / 1000);
    const v1 = createHmac('sha256', secret).update(`${t}.${body}`).digest('hex');
    for (const [header, payload, key] of [
      [sdk(undefined, body, 'whsec_other'), body, secret],
      [sdk(), body.replace('evt_1', 'evt_2'), secret],
      [sdk(), body, secret.replace('whsec_', '')], // the key is the whole whsec_ string
      [`t=${t}`, body, secret],
      [`v1=${v1}`, body, secret],
      [`t=${t}abc,v1=${v1}`, body, secret],
      [`t=${t},v1=${v1.toUpperCase()}`, body, secret],
      [`t=${t},v1=${v1.slice(1)}`, body, secret],
      ['', body, secret],
      [null, body, secret],
    ] as [string | null, string, string][])
      await expect(verifyWebhook(payload, header, key, now), String(header)).rejects.toThrow();
  });

  it('refuses a signature older or newer than 300 s (a replay)', async () => {
    const t = Math.floor(now / 1000);
    expect(await verifyWebhook(body, sdk(t - 299), secret, now)).toBeTruthy();
    await expect(verifyWebhook(body, sdk(t - 301), secret, now)).rejects.toThrow(/too old/);
    await expect(verifyWebhook(body, sdk(t + 301), secret, now)).rejects.toThrow(/in the future/);
  });
});
