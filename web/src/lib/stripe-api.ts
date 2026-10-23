import type Stripe from 'stripe';

// The Stripe calls lib/stripe.ts makes, over fetch, in place of the stripe SDK at runtime: the SDK's setup cost about
// 13-15 ms of CPU in a fresh isolate, more than a request may use on the Workers Free plan. Same endpoints, the SDK's
// form encoding (nested[key], arrays by index, GET and DELETE in the query), the API version pinned per call.
// Typed as the SDK (`import type`, nothing of it is loaded), narrowed to the methods below (StripeClient), so tsc
// refuses a call this client does not make. Like the SDK, it retries what is safe to send twice (below).

export const API_VERSION = '2025-02-24.acacia';

/** Stripe's answer to a failed call: its error type, code and message, never the request (no key, no params). */
export class StripeApiError extends Error {
  constructor(
    readonly type: string,
    readonly code: string | undefined,
    message: string,
    readonly statusCode: number,
  ) {
    super(message);
  }
}

type Params = Record<string, unknown>;
type Options = { apiVersion?: string; idempotencyKey?: string };

/** The SDK's surface lib/stripe.ts may use: exactly what stripeApi() implements, so a call to anything else fails tsc. */
export type StripeClient = {
  prices: Pick<Stripe.PricesResource, 'list'>;
  promotionCodes: Pick<Stripe.PromotionCodesResource, 'list'>;
  customers: Pick<Stripe.CustomersResource, 'create'>;
  checkout: { sessions: Pick<Stripe.Checkout.SessionsResource, 'list' | 'create' | 'expire'> };
  billingPortal: {
    configurations: Pick<Stripe.BillingPortal.ConfigurationsResource, 'list'>;
    sessions: Pick<Stripe.BillingPortal.SessionsResource, 'create'>;
  };
  subscriptions: Pick<Stripe.SubscriptionsResource, 'retrieve' | 'update' | 'cancel'>;
  invoices: Pick<Stripe.InvoicesResource, 'list' | 'retrieve' | 'voidInvoice'>;
  refunds: Pick<Stripe.RefundsResource, 'create'>;
};
/** StripeClient's keys, every method a function: the object below must have each one, and nothing more. */
type Shape<T> = { [K in keyof T]: T[K] extends (...a: never[]) => unknown ? (...a: never[]) => unknown : Shape<T[K]> };

/**
 * Retries, as the SDK made them: a GET, or a POST or DELETE that carries an Idempotency-Key (Stripe answers its
 * repeat with the first answer), after a 429, a 5xx or a network error, at most twice, 0.5 s then 1 s (with jitter,
 * or Stripe's Retry-After, at most 5 s). Never when Stripe says Stripe-Should-Retry: false. Waiting costs no CPU.
 */
export const MAX_RETRIES = 2;
const retryable = (status: number) => status === 429 || status >= 500;
export function retryDelay(attempt: number, res?: Response, random = Math.random): number {
  const after = Number(res?.headers.get('retry-after'));
  const ms = after > 0 ? after * 1000 : 500 * 2 ** attempt * (0.75 + random() / 4);
  return Math.min(ms, 5000);
}
const wait = (ms: number) => new Promise<void>((done) => setTimeout(done, ms));

/** application/x-www-form-urlencoded as the SDK sends it: a[b]=1, a[0][b]=1, booleans as text, '' kept, undefined left out. */
export function formEncode(params: Params, prefix = '', out: string[] = []): string {
  for (const [k, v] of Object.entries(params)) {
    if (v === undefined) continue;
    const key = prefix ? `${prefix}[${k}]` : k;
    if (v !== null && typeof v === 'object') formEncode(v as Params, key, out);
    else out.push(`${encodeURIComponent(key)}=${encodeURIComponent(v === null ? '' : String(v))}`);
  }
  return out.join('&').replace(/%5B/g, '[').replace(/%5D/g, ']');
}

export function stripeApi(key: string, base = 'https://api.stripe.com', sleep = wait): StripeClient {
  async function call(method: string, path: string, params: Params = {}, opts: Options = {}) {
    const form = formEncode(params);
    const query = method === 'GET' || method === 'DELETE';
    const headers: Record<string, string> = { authorization: `Bearer ${key}`, 'stripe-version': opts.apiVersion ?? API_VERSION };
    if (opts.idempotencyKey) headers['idempotency-key'] = opts.idempotencyKey;
    if (!query) headers['content-type'] = 'application/x-www-form-urlencoded';
    const url = `${base}/v1${path}${query && form ? `?${form}` : ''}`;
    const repeatable = method === 'GET' || !!opts.idempotencyKey;
    let res: Response;
    for (let attempt = 0; ; attempt++) {
      const again = repeatable && attempt < MAX_RETRIES;
      try {
        res = await fetch(url, { method, headers, body: query ? undefined : form });
      } catch (e) {
        if (!again) throw e;
        await sleep(retryDelay(attempt));
        continue;
      }
      if (!again || !retryable(res.status) || res.headers.get('stripe-should-retry') === 'false') break;
      await res.body?.cancel();
      await sleep(retryDelay(attempt, res));
    }
    const body = (await res.json().catch(() => ({}))) as { error?: { type?: string; code?: string; message?: string } };
    if (!res.ok) {
      const e = body.error ?? {};
      throw new StripeApiError(e.type ?? 'api_error', e.code, e.message ?? `Stripe answered ${res.status}`, res.status);
    }
    return body;
  }
  const id = (s: string) => encodeURIComponent(s);
  /** A list: awaited, the first page; iterated (for await), every item, page after page. */
  const list = (path: string) => (params: Params = {}) => {
    const first = call('GET', path, params) as Promise<{ data: { id: string }[]; has_more: boolean }>;
    return Object.assign(first, {
      async *[Symbol.asyncIterator]() {
        for (let page = await first; ; ) {
          yield* page.data;
          if (!page.has_more || !page.data.length) return;
          page = (await call('GET', path, { ...params, starting_after: page.data[page.data.length - 1].id })) as typeof page;
        }
      },
    });
  };
  const create = (path: string) => (params: Params, opts?: Options) => call('POST', path, params, opts);
  const client = {
    prices: { list: list('/prices') },
    promotionCodes: { list: list('/promotion_codes') },
    customers: { create: create('/customers') },
    checkout: {
      sessions: { list: list('/checkout/sessions'), create: create('/checkout/sessions'), expire: (s: string) => call('POST', `/checkout/sessions/${id(s)}/expire`) },
    },
    billingPortal: { configurations: { list: list('/billing_portal/configurations') }, sessions: { create: create('/billing_portal/sessions') } },
    subscriptions: {
      retrieve: (s: string) => call('GET', `/subscriptions/${id(s)}`),
      update: (s: string, p: Params, o?: Options) => call('POST', `/subscriptions/${id(s)}`, p, o),
      cancel: (s: string, p?: Params, o?: Options) => call('DELETE', `/subscriptions/${id(s)}`, p, o),
    },
    invoices: { list: list('/invoices'), retrieve: (s: string) => call('GET', `/invoices/${id(s)}`), voidInvoice: (s: string) => call('POST', `/invoices/${id(s)}/void`) },
    refunds: { create: create('/refunds') },
  } satisfies Shape<StripeClient>;
  // The answers are Stripe's JSON as the SDK would return it; the types are the SDK's.
  return client as unknown as StripeClient;
}

const enc = new TextEncoder();
const keys = new Map<string, Promise<CryptoKey>>();
const hexBytes = (h: string) => Uint8Array.from(h.match(/../g)!, (b) => parseInt(b, 16));

/**
 * A Stripe webhook's event, if its Stripe-Signature holds: t (whole seconds) within 300 s of now either way, and an
 * HMAC-SHA256 over `${t}.${body}` keyed with the whole whsec_ secret in any of its v1 entries. Throws otherwise.
 */
export async function verifyWebhook(body: string, header: string | null, secret: string, now = Date.now()): Promise<Stripe.Event> {
  let t = '';
  const v1: string[] = [];
  // Parsed as the SDK parses it (no trimming: ' v1=…' is not a v1), only stricter: t is digits, a v1 is 64 hex.
  for (const item of (header ?? '').split(',')) {
    const [k, v = ''] = item.split('=', 2);
    if (k === 't') t = v;
    else if (k === 'v1' && /^[0-9a-f]{64}$/.test(v)) v1.push(v);
  }
  if (!/^\d+$/.test(t) || !v1.length) throw new Error('no Stripe signature');
  // Whole seconds, as the SDK counts them; the SDK takes any future t, this takes 300 s.
  if (Math.abs(Math.floor(now / 1000) - Number(t)) > 300) throw new Error('Stripe signature too old or in the future');
  let key = keys.get(secret);
  if (!key) keys.set(secret, (key = crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['verify'])));
  const data = enc.encode(`${t}.${body}`);
  for (const sig of v1) if (await crypto.subtle.verify('HMAC', await key, hexBytes(sig), data)) return JSON.parse(body) as Stripe.Event;
  throw new Error('no matching Stripe signature');
}
