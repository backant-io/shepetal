import { createHmac } from 'node:crypto';
import Stripe from 'stripe';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { formEncode, MAX_RETRIES, retryDelay, StripeApiError, stripeApi, verifyWebhook } from './stripe-api';

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

// The SDK retried a failed call twice when it was safe to send again (lib/stripe.ts relied on that: a 429 or a
// passing 5xx at checkout would otherwise be an error on the buyer's screen). A POST without an Idempotency-Key may
// have been done by Stripe before the answer was lost, so it is never sent twice.
describe('retries', () => {
  const calls: RequestInit[] = [];
  const sleeps: number[] = [];
  /** fetch answering each call in turn: a status (with headers), or 'network' for a rejected fetch. */
  const answer = (...steps: (number | 'network' | [number, Record<string, string>])[]) => {
    calls.length = 0;
    sleeps.length = 0;
    vi.stubGlobal('fetch', async (_url: string, init: RequestInit) => {
      calls.push(init);
      const step = steps.shift()!;
      if (step === 'network') throw new TypeError('Network connection lost.');
      const [status, headers] = typeof step === 'number' ? [step, {}] : step;
      return Response.json(status === 200 ? { id: 'ok', data: [], has_more: false } : { error: { type: 'api_error', message: `status ${status}` } }, { status, headers });
    });
  };
  const s = stripeApi('sk_test_x', 'http://127.0.0.1:1', async (ms) => void sleeps.push(ms));

  it('retries a GET after a 429, a 5xx or a network error, at most twice, with backoff', async () => {
    answer(500, 'network', 200);
    expect(await s.subscriptions.retrieve('sub_1')).toMatchObject({ id: 'ok' });
    expect(calls).toHaveLength(3);
    expect(sleeps[0]).toBeGreaterThanOrEqual(375);
    expect(sleeps[0]).toBeLessThanOrEqual(500);
    expect(sleeps[1]).toBeGreaterThanOrEqual(750);
    expect(sleeps[1]).toBeLessThanOrEqual(1000);

    answer(503, 502, 500, 200);
    await expect(s.prices.list({ limit: 1 })).rejects.toMatchObject({ statusCode: 500 });
    expect(calls).toHaveLength(1 + MAX_RETRIES);
    expect(MAX_RETRIES).toBe(2);

    answer('network', 'network', 'network');
    await expect(s.invoices.retrieve('in_1')).rejects.toThrow('Network connection lost.');
    expect(calls).toHaveLength(3);

    answer([429, { 'retry-after': '2' }], 200);
    await s.invoices.retrieve('in_1');
    expect(sleeps).toEqual([2000]); // Stripe's Retry-After
  });

  it('retries a POST or DELETE only with an Idempotency-Key, sending the same key and body again', async () => {
    answer('network', 503, 200);
    await s.refunds.create({ payment_intent: 'pi_1' }, { idempotencyKey: 'shepetal-refund-pi_1' });
    expect(calls).toHaveLength(3);
    for (const c of calls) expect([c.body, (c.headers as Record<string, string>)['idempotency-key']]).toEqual(['payment_intent=pi_1', 'shepetal-refund-pi_1']);

    answer(500, 200);
    await s.subscriptions.cancel('sub_1', { prorate: false }, { idempotencyKey: 'shepetal-end-sub_1' });
    expect(calls.map((c) => c.method)).toEqual(['DELETE', 'DELETE']);

    for (const fail of [500, 429, 'network'] as const) {
      answer(fail, 200);
      await expect(s.subscriptions.update('sub_1', { cancel_at_period_end: true })).rejects.toThrow();
      expect(calls, String(fail)).toHaveLength(1);
    }
    answer(500, 200);
    await expect(s.checkout.sessions.expire('cs_1')).rejects.toThrow();
    expect(calls).toHaveLength(1);
  });

  it('never retries a 4xx other than 429, or what Stripe marks Stripe-Should-Retry: false', async () => {
    for (const status of [400, 401, 402, 404, 409]) {
      answer(status, 200);
      await expect(s.subscriptions.retrieve('sub_1')).rejects.toMatchObject({ statusCode: status });
      expect(calls).toHaveLength(1);
    }
    answer([503, { 'stripe-should-retry': 'false' }], 200);
    await expect(s.subscriptions.retrieve('sub_1')).rejects.toMatchObject({ statusCode: 503 });
    expect(calls).toHaveLength(1);
  });

  it('waits 0.5 s, then 1 s, with jitter, never more than 5 s', () => {
    expect([retryDelay(0, undefined, () => 0), retryDelay(0, undefined, () => 1)]).toEqual([375, 500]);
    expect([retryDelay(1, undefined, () => 0), retryDelay(1, undefined, () => 1)]).toEqual([750, 1000]);
    expect(retryDelay(0, new Response(null, { headers: { 'retry-after': '60' } }))).toBe(5000);
    expect(retryDelay(0, new Response(null, { headers: { 'retry-after': 'soon' } }), () => 1)).toBe(500);
  });
});

it('is typed as only what it implements: tsc refuses any other Stripe call', () => {
  const s = stripeApi('sk_test_x');
  // @ts-expect-error: coupons are not implemented by the fetch client
  expect(s.coupons).toBeUndefined();
  // @ts-expect-error: subscriptions.list is not implemented
  expect(s.subscriptions.list).toBeUndefined();
  // @ts-expect-error: webhooks are checked by verifyWebhook, not the client
  expect(s.webhooks).toBeUndefined();
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

  // The SDK is the reference: for these payloads, secrets, timestamps and headers, verifyWebhook accepts exactly
  // what stripe.webhooks.constructEvent (tolerance 300 s) accepts, except a t more than 300 s in the future, which
  // the SDK lets through and this refuses.
  it('agrees with the Stripe SDK’s own verifier on SDK-signed headers', async () => {
    const stripe = new Stripe('sk_test_x');
    const at = 1_790_000_000_750; // not a whole second: the SDK counts whole seconds
    const nowS = Math.floor(at / 1000);
    const payloads = [body, '{}', JSON.stringify({ id: 'evt_2', object: 'event', data: { object: { amount: 2399 } } }, null, 2), '{"a":"\\u00e9 é\\r\\n","b":[1,2]}\r\n'];
    const secrets = [secret, 'whsec_Zm9vYmFyYmF6cXV4K/9+==', 'whsec_' + 'x'.repeat(64)];
    const ages = [0, 1, 299, 300, 301, 3600, -1, -299, -300, -301, -3600];
    let checked = 0;
    for (const payload of payloads)
      for (const key of secrets)
        for (const age of ages) {
          const t = nowS - age;
          const sign = (k = key, scheme?: string, p = payload) => stripe.webhooks.generateTestHeaderString({ payload: p, secret: k, timestamp: t, scheme });
          const good = sign().split(',')[1];
          const other = sign('whsec_other').split(',')[1];
          const headers = [
            sign(),
            `t=${t},${other},${good}`, // several v1: any may match (secret rotation)
            `t=${t},${good},${other}`,
            `t=${t},${other}`,
            sign(key, 'v0'), // the wrong scheme
            `${sign(key, 'v0')},${good}`,
            `t=${t}, ${good}`, // a space: not a v1 to the SDK
            `${good},t=${t}`,
            `t=${t},${good.toUpperCase().replace('V1', 'v1')}`,
            sign(key, undefined, payload + ' '), // signed for another body
          ];
          for (const header of headers) {
            const sdkOk = (() => {
              try {
                stripe.webhooks.constructEvent(payload, header, key, 300, undefined, at);
                return true;
              } catch {
                return false;
              }
            })();
            const ours = await verifyWebhook(payload, header, key, at).then(() => true, () => false);
            expect(ours, JSON.stringify({ payload, key, age, header })).toBe(sdkOk && age >= -300);
            if (header === headers[0]) expect(sdkOk).toBe(age <= 300); // the SDK's own header: only too old fails there
            checked++;
          }
        }
    expect(checked).toBe(payloads.length * secrets.length * ages.length * 10);
    // The secret is checked whole: the right one with or without whsec_, or with whitespace, is another key.
    const header = stripe.webhooks.generateTestHeaderString({ payload: body, secret, timestamp: nowS });
    for (const key of [secret.slice(6), `${secret} `, `${secret}\n`, secret.toUpperCase()])
      await expect(verifyWebhook(body, header, key, at), JSON.stringify(key)).rejects.toThrow();
  });

  it('refuses a signature older or newer than 300 s (a replay)', async () => {
    const t = Math.floor(now / 1000);
    expect(await verifyWebhook(body, sdk(t - 299), secret, now)).toBeTruthy();
    await expect(verifyWebhook(body, sdk(t - 301), secret, now)).rejects.toThrow(/too old/);
    await expect(verifyWebhook(body, sdk(t + 301), secret, now)).rejects.toThrow(/in the future/);
  });
});
