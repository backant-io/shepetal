/**
 * Product analytics, cookieless, in backant's shared PostHog project (US cloud). Every event carries app=shepetal.
 * Off unless POSTHOG_KEY is set (a Worker secret, set at GO). POSTHOG_HOST is in wrangler.toml [vars].
 *
 * Server-side events go from the Worker to PostHog's capture API: download_served, appcast_check (= active),
 * license_first_call (= install) and checkout_completed (= paid). Visitors are a hash of IP + user agent + the UTC
 * day, salted with AUTH_SECRET: nothing raw is stored or sent, and the id changes every day. Signed-in users are a
 * salted hash of their email. Nothing about dictation is ever sent: the app has no analytics at all.
 */
export type Props = Record<string, string | number | boolean | null | undefined>;

import { analyticsConfig } from './analytics-config';

export { analyticsConfig };

const hex = (buf: ArrayBuffer) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
async function sha256(s: string): Promise<string> {
  return hex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)));
}

/** A visitor for one UTC day: sha256(day, IP, user agent, salt). Never the IP or the user agent themselves. */
export async function visitorId(req: Request, now = Date.now(), salt = process.env.AUTH_SECRET ?? ''): Promise<string> {
  const ip = req.headers.get('cf-connecting-ip') ?? req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ?? '';
  const ua = req.headers.get('user-agent') ?? '';
  const day = new Date(now).toISOString().slice(0, 10);
  return `v_${(await sha256(`${day}\n${ip}\n${ua}\n${salt}`)).slice(0, 32)}`;
}

/** A signed-in user: a salted hash of the email, the same every day, so installs and payments join up. */
export async function userId(email: string, salt = process.env.AUTH_SECRET ?? ''): Promise<string> {
  return `u_${(await sha256(`user\n${email.toLowerCase()}\n${salt}`)).slice(0, 32)}`;
}

const ATTRIBUTION = ['ref', 'utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content'] as const;
export type Attribution = Partial<Record<(typeof ATTRIBUTION)[number], string>>;

/** ref (?ref=<site>) and the UTM fields of a URL, each up to 64 characters of letters, digits, . _ - and +. */
export function attribution(params: URLSearchParams | { get(name: string): unknown }): Attribution {
  const out: Attribution = {};
  for (const k of ATTRIBUTION) {
    const v = params.get(k);
    if (typeof v === 'string' && /^[\w.+-]{1,64}$/.test(v)) out[k] = v;
  }
  return out;
}

/** The query string that carries attribution on to the next page ('' when there is none). */
export function attributionQuery(a: Attribution): string {
  const q = new URLSearchParams(Object.entries(a).filter(([, v]) => v) as [string, string][]).toString();
  return q ? `?${q}` : '';
}

/**
 * Sends one event to PostHog's capture API. Never throws, never blocks the answer for long, and does nothing without
 * a key. A visitor (v_…) gets no person profile; a user (u_…) does, tagged app=shepetal.
 */
export async function capture(
  event: string,
  distinctId: string,
  props: Props = {},
  env: Record<string, string | undefined> = process.env,
  fetchImpl: typeof fetch = fetch,
): Promise<boolean> {
  const { key, host } = analyticsConfig(env);
  if (!key) return false;
  const person = distinctId.startsWith('u_');
  const body = {
    api_key: key,
    event,
    distinct_id: distinctId,
    timestamp: new Date().toISOString(),
    properties: {
      ...props,
      app: 'shepetal',
      $lib: 'shepetal-worker',
      $geoip_disable: true,
      ...(person ? { $set: { app: 'shepetal' } } : { $process_person_profile: false }),
    },
  };
  try {
    const r = await fetchImpl(`${host}/i/v0/e/`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(3000),
    });
    return r.ok;
  } catch {
    return false;
  }
}

/** capture() after the answer has gone (the Worker's waitUntil), or right away where there is no Worker context. */
export async function track(event: string, distinctId: string | Promise<string>, props: Props = {}): Promise<void> {
  if (!analyticsConfig().key) return;
  const job = (async () => capture(event, await distinctId, props))();
  try {
    const { getCloudflareContext } = await import('@opennextjs/cloudflare');
    getCloudflareContext().ctx.waitUntil(job);
  } catch {
    await job;
  }
}
