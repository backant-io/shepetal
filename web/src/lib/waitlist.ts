import { sesSend, type SesEnv } from './ses';

/**
 * The waitlist for Windows, Linux and iPhone (/waitlist, API.md), answered by worker.ts without Next: the Workers Free
 * plan gives a request 10 ms of CPU. Double opt-in: a signup stores the row and sends a confirmation email with a link
 * signed under AUTH_SECRET; only a confirmed row that is not unsubscribed counts. The POST answers with the same
 * redirect to the static thanks page whether the email is new, pending, confirmed or throttled, so the form never
 * tells anyone whether an address is on the list.
 */
export type WaitlistEnv = SesEnv & { DB: D1Database; AUTH_SECRET?: string; WAITLIST_EMAILS?: string };
/** ctx.waitUntil: the email goes out after the answer, so the answer takes as long whether one is sent or not. */
export type Defer = (p: Promise<unknown>) => void;

export const PLATFORMS = { windows: 'Windows', linux: 'Linux', iphone: 'iPhone' } as const;
export type Platform = keyof typeof PLATFORMS;

/** The checkbox's words. The form shows exactly this, and each row stores what it showed. */
export const CONSENT_TEXT = 'Email me when shepetal comes to my platform. Unsubscribe anytime.';

/** Where each answer goes: static pages, prerendered and served from the cache. */
export const PAGE = {
  thanks: '/waitlist/thanks',
  check: '/waitlist/check',
  confirmed: '/waitlist/confirmed',
  unsubscribe: '/waitlist/unsubscribe',
  unsubscribed: '/waitlist/unsubscribed',
  badLink: '/waitlist/link',
} as const;

/** At most this many signups an hour from one IP address; more are dropped, with the same thanks page. */
export const IP_PER_HOUR = 10;
/** At most one confirmation email per address in this many minutes. */
export const MAIL_EVERY_MIN = 30;
/** A confirmation link works this many days. */
export const CONFIRM_DAYS = 7;
/** A row that is not confirmed and subscribed goes this many days after its last signup (the daily sweep). Under 30, so
 * with a daily sweep it is gone within 30 days, as the privacy policy says. */
export const KEEP_DAYS = 29;

const MIN = 60_000;
const DAY = 86_400_000;
const iso = (ms: number) => new Date(ms).toISOString();
const see = (path: string) => new Response(null, { status: 303, headers: { location: path, 'cache-control': 'no-store' } });

/** A plain address: one @, a dotted domain, nothing that needs quoting. Lowercased, or null. */
export function normalEmail(s: string | null): string | null {
  const e = (s ?? '').trim().toLowerCase();
  if (e.length > 254 || !/^[a-z0-9.!#$%&'*+/=?^_`{}|~-]{1,64}@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/.test(e)) return null;
  if (e.startsWith('.') || e.includes('..') || e.split('@')[0].endsWith('.')) return null;
  return e;
}

/** The chosen platforms, known ones only, sorted and once each. */
export function platformsOf(values: string[]): Platform[] {
  return [...new Set(values.filter((v): v is Platform => Object.hasOwn(PLATFORMS, v)))].sort();
}

// --- signed links ---------------------------------------------------------------------------------------------------

type Signed = { k: 'c'; e: string; p: Platform[]; t: number } | { k: 'u'; e: string };

const enc = (s: string) => new TextEncoder().encode(s);
const b64url = (b: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const unb64url = (s: string) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));

async function mac(secret: string, s: string): Promise<ArrayBuffer> {
  const k = await crypto.subtle.importKey('raw', enc(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  // A prefix of its own, so no other use of AUTH_SECRET signs the same bytes.
  return crypto.subtle.sign('HMAC', k, enc(`shepetal-waitlist:${s}`));
}

export async function sign(secret: string, v: Signed): Promise<string> {
  const payload = b64url(enc(JSON.stringify(v)));
  return `${payload}.${b64url(await mac(secret, payload))}`;
}

/** The signed value, or null for anything not signed with this secret. Compared in constant time. */
export async function verify(secret: string, token: string | null): Promise<Signed | null> {
  const m = token?.match(/^([\w-]{1,1000})\.([\w-]{43})$/);
  if (!m) return null;
  // As text, not bytes: the last base64url character has spare bits, and a changed link is a changed link.
  const want = b64url(await mac(secret, m[1]));
  let diff = 0;
  for (let i = 0; i < want.length; i++) diff |= want.charCodeAt(i) ^ m[2].charCodeAt(i);
  if (diff) return null;
  try {
    return JSON.parse(new TextDecoder().decode(unb64url(m[1]))) as Signed;
  } catch {
    return null;
  }
}

const secretOf = (env: WaitlistEnv) => {
  if (!env.AUTH_SECRET) throw new Error('AUTH_SECRET is not set');
  return env.AUTH_SECRET;
};

// --- POST /api/waitlist ---------------------------------------------------------------------------------------------

type Row = { platforms: string; confirmed_at: string | null; unsubscribed_at: string | null; last_mail_at: string | null };

/** POST /api/waitlist, the form (email, platform, consent). */
export async function signup(req: Request, env: WaitlistEnv, defer: Defer, now = Date.now()): Promise<Response> {
  const url = new URL(req.url);
  // Same site only: a browser always sends Origin on a cross-site POST, and a form on this site sends this origin.
  if (req.headers.get('origin') !== url.origin) return new Response('Forbidden', { status: 403, headers: { 'cache-control': 'no-store' } });
  const raw = await req.text();
  const form = new URLSearchParams(raw.length <= 2048 ? raw : '');
  const email = normalEmail(form.get('email'));
  const platforms = platformsOf(form.getAll('platform'));
  // The browser asks for the email and the box itself; a missing platform (no script checks it) or a request made by
  // hand lands here.
  if (!email || !platforms.length || form.get('consent') !== 'yes') return see(PAGE.check);

  try {
    await store(req, env, defer, url, email, platforms, now);
  } catch (e) {
    // Still the thanks page: the answer never differs by address, even when the database fails. The log has it.
    console.error('waitlist: signup failed', e);
  }
  return see(PAGE.thanks);
}

async function store(req: Request, env: WaitlistEnv, defer: Defer, url: URL, email: string, platforms: Platform[], now: number) {
  const secret = secretOf(env);
  const ip = req.headers.get('cf-connecting-ip') ?? '';
  const ipHash = b64url(await mac(secret, `ip:${ip}`)).slice(0, 32);
  const DB = env.DB;
  const recent = await DB.prepare('SELECT COUNT(*) AS n FROM waitlist WHERE ip_hash = ?1 AND last_request_at > ?2')
    .bind(ipHash, iso(now - 60 * MIN))
    .first<{ n: number }>();
  // Dropped, with the same thanks page.
  if ((recent?.n ?? 0) >= IP_PER_HOUR) return;

  const list = platforms.join(',');
  const row = await DB.prepare('SELECT platforms, confirmed_at, unsubscribed_at, last_mail_at FROM waitlist WHERE email = ?1').bind(email).first<Row>();
  let mail: boolean;
  if (!row) {
    await DB.prepare(
      `INSERT INTO waitlist (email, platforms, created_at, consent_text, ip_hash, last_request_at) VALUES (?1, ?2, ?3, ?4, ?5, ?3)
       ON CONFLICT (email) DO NOTHING`,
    )
      .bind(email, list, iso(now), CONSENT_TEXT, ipHash)
      .run();
    mail = true;
  } else {
    const active = row.confirmed_at && !row.unsubscribed_at;
    // A pending row takes the new choice now; a confirmed or unsubscribed one only once the new link is clicked.
    await DB.prepare(
      `UPDATE waitlist SET ip_hash = ?2, last_request_at = ?3, consent_text = ?4, platforms = CASE WHEN confirmed_at IS NULL THEN ?5 ELSE platforms END
       WHERE email = ?1`,
    )
      .bind(email, ipHash, iso(now), CONSENT_TEXT, list)
      .run();
    const fresh = !row.last_mail_at || row.last_mail_at <= iso(now - MAIL_EVERY_MIN * MIN);
    mail = fresh && !(active && row.platforms === list);
  }
  if (mail) {
    await DB.prepare('UPDATE waitlist SET last_mail_at = ?2 WHERE email = ?1').bind(email, iso(now)).run();
    defer(sendConfirmation(env, url.origin, email, platforms, now).catch((e) => console.error('waitlist: confirmation email failed', e)));
  }
}

/** The confirmation email, or with WAITLIST_EMAILS anything but "on", the log line of the email it would send. */
export async function sendConfirmation(env: WaitlistEnv, origin: string, email: string, platforms: Platform[], now = Date.now()) {
  const secret = secretOf(env);
  const confirm = `${origin}/api/waitlist/confirm?t=${await sign(secret, { k: 'c', e: email, p: platforms, t: now })}`;
  const unsubscribe = `${origin}/api/waitlist/unsubscribe?t=${await sign(secret, { k: 'u', e: email })}`;
  const names = platforms.map((p) => PLATFORMS[p]);
  const which = names.length > 1 ? `${names.slice(0, -1).join(', ')} or ${names.at(-1)}` : names[0];
  const m = {
    to: email,
    subject: 'Confirm your place on the shepetal waitlist',
    text: [
      `You asked to hear when shepetal comes to ${which}. Confirm it with this link:`,
      '',
      confirm,
      '',
      `The link works for ${CONFIRM_DAYS} days. If you did not ask for this, ignore this email: you hear nothing more from us, and we delete your address within 30 days.`,
      '',
      `Unsubscribe: ${unsubscribe}`,
      '',
      'shepetal',
      'BackAnt, Inc., 131 Continental Dr, Suite 305, Newark, DE 19713, USA',
    ].join('\n'),
    // RFC 8058 one-click unsubscribe: mail apps POST "List-Unsubscribe=One-Click" to this URL.
    headers: { 'List-Unsubscribe': `<${unsubscribe}>`, 'List-Unsubscribe-Post': 'List-Unsubscribe=One-Click' },
  };
  if (env.WAITLIST_EMAILS !== 'on') {
    console.log(JSON.stringify({ waitlist_email_not_sent: 'WAITLIST_EMAILS is off', ...m }));
    return;
  }
  await sesSend(env, m, new Date(now));
}

// --- GET /api/waitlist/confirm, GET and POST /api/waitlist/unsubscribe ------------------------------------------------

/** GET /api/waitlist/confirm?t=: the link in the confirmation email. */
export async function confirm(req: Request, env: WaitlistEnv, now = Date.now()): Promise<Response> {
  const v = await verify(secretOf(env), new URL(req.url).searchParams.get('t'));
  if (v?.k !== 'c' || !(now - v.t < CONFIRM_DAYS * DAY) || !Array.isArray(v.p)) return see(PAGE.badLink);
  const platforms = platformsOf(v.p);
  if (!platforms.length) return see(PAGE.badLink);
  // A link sent before an unsubscribe never subscribes again: only a newer signup's link does.
  const done = await env.DB.prepare(
    `UPDATE waitlist SET platforms = ?2,
       confirmed_at = CASE WHEN confirmed_at IS NULL OR unsubscribed_at IS NOT NULL THEN ?3 ELSE confirmed_at END,
       unsubscribed_at = NULL
     WHERE email = ?1 AND (unsubscribed_at IS NULL OR unsubscribed_at < ?4)`,
  )
    .bind(v.e, platforms.join(','), iso(now), iso(v.t))
    .run();
  return see(done.meta.changes ? PAGE.confirmed : PAGE.badLink);
}

/** GET /api/waitlist/unsubscribe?t= (the List-Unsubscribe URL opened in a browser): the page with the button, never the
 * unsubscribe itself, since link checkers open every link (RFC 8058). */
export function unsubscribePage(req: Request): Response {
  const t = new URL(req.url).searchParams.get('t') ?? '';
  return see(/^[\w-]+\.[\w-]+$/.test(t) ? `${PAGE.unsubscribe}?t=${t}` : PAGE.unsubscribe);
}

/** POST /api/waitlist/unsubscribe: the page's button (t in the form), or a mail app's one-click POST (t in the URL,
 * body List-Unsubscribe=One-Click, from no site at all, so no Origin check: the signature is the proof). */
export async function unsubscribe(req: Request, env: WaitlistEnv, now = Date.now()): Promise<Response> {
  const raw = await req.text();
  const form = new URLSearchParams(raw.length <= 2048 ? raw : '');
  const oneClick = form.get('List-Unsubscribe') === 'One-Click';
  const v = await verify(secretOf(env), form.get('t') ?? new URL(req.url).searchParams.get('t'));
  if (v?.k !== 'u') return oneClick ? new Response('Bad link', { status: 400 }) : see(PAGE.badLink);
  await env.DB.prepare('UPDATE waitlist SET unsubscribed_at = ?2 WHERE email = ?1 AND unsubscribed_at IS NULL').bind(v.e, iso(now)).run();
  return oneClick ? new Response('Unsubscribed', { headers: { 'cache-control': 'no-store' } }) : see(PAGE.unsubscribed);
}

/** The daily sweep (worker.ts scheduled): a row that is not confirmed and subscribed goes KEEP_DAYS after its last signup. */
export async function sweep(DB: D1Database, now = Date.now()): Promise<number> {
  const r = await DB.prepare('DELETE FROM waitlist WHERE last_request_at < ?1 AND (confirmed_at IS NULL OR unsubscribed_at IS NOT NULL)')
    .bind(iso(now - KEEP_DAYS * DAY))
    .run();
  return r.meta.changes;
}
