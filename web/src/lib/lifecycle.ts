import { licenseOf, TRIAL_DAYS, type User } from './account';
import { db } from './db';
import { copyFor, render, type Kind } from './lifecycle-copy';
import { sesConfigured, SesError, sesSend, type SesEnv } from './mail';
import { SITE_URL } from './site';

/**
 * The trial emails: welcome, a tip on day 3, and on day 25 the note that the trial ends in 5 days. Off for now: the
 * sign-in no longer asks for the opt-in, LIFECYCLE_EMAILS is "off" and the Cron Trigger (wrangler.toml [triggers])
 * runs once a day for the waitlist sweep only. To bring them back: an opt-in that sets users.trial_emails_at, the
 * cron every 5 minutes, and LIFECYCLE_EMAILS = "on". The cron then calls runLifecycle from worker.ts. Each run sends at most BATCH emails:
 * the Workers Free plan gives a cron run 10 ms of CPU, like a request. That is 1,440 a day.
 *
 * - Only users who opted in get them (users.trial_emails_at; no sign-in sets it now).
 * - Each email has a window after trial_started_at. Outside it nothing is sent, so switching this on later never
 *   sends a welcome to someone in their third week.
 * - day25 only goes to a user still on the free trial (no lifetime license, no subscription, ever).
 * - lifecycle_emails is claimed before SES is called, so no email goes out twice.
 * - Users in email_unsubscribes get nothing.
 * - A fault of the setup (SES paused, a wrong region, 5xx) stops the run and costs no email (runLifecycle).
 * - LIFECYCLE_EMAILS (wrangler.toml [vars]) is the kill switch: only "on" sends; anything else logs what would go.
 */
export type { Kind };
export const KINDS: Kind[] = ['day25', 'welcome', 'day3']; // the order a full batch is filled in
export const BATCH = 5;
const DAY = 86_400_000;

/** [from, to) after trial_started_at. day25 is one day wide, so "ends in 5 days" holds when it is sent. */
export const WINDOWS: Record<Kind, [number, number]> = {
  welcome: [0, 2 * DAY],
  day3: [3 * DAY, 5 * DAY],
  day25: [25 * DAY, 26 * DAY],
};

export type LifecycleEnv = SesEnv & { DB: D1Database; AUTH_SECRET?: string; LIFECYCLE_EMAILS?: string };
export type Due = { kind: Kind; user: User };
export type Outcome = { kind: Kind; user_id: number; result: 'sent' | 'would_send' | 'skipped' | 'retry' | 'failed'; detail?: string };

const iso = (ms: number) => new Date(ms).toISOString();

/**
 * The emails due at `now`, at most `limit`, in one query: day25 first (it cannot wait), then welcome, then day3.
 * Only to users who opted in (users.trial_emails_at) and never unsubscribed.
 */
export async function due(DB: D1Database, now: number, limit = BATCH): Promise<Due[]> {
  const parts = KINDS.map(
    (kind, i) => `SELECT ${i} AS prio, '${kind}' AS kind, u.* FROM users u
      WHERE u.trial_started_at > ?${2 * i + 1} AND u.trial_started_at <= ?${2 * i + 2}
        ${kind === 'day25' ? "AND u.status = 'trial' AND u.plan IS NULL" : ''}
        AND u.trial_emails_at IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM lifecycle_emails e WHERE e.user_id = u.id AND e.kind = '${kind}')
        AND NOT EXISTS (SELECT 1 FROM email_unsubscribes x WHERE x.user_id = u.id)`,
  );
  const binds = KINDS.flatMap((k) => [iso(now - WINDOWS[k][1]), iso(now - WINDOWS[k][0])]);
  const { results } = await DB.prepare(`${parts.join(' UNION ALL ')} ORDER BY prio, trial_started_at LIMIT ${limit | 0}`)
    .bind(...binds)
    .all<User & { prio: number; kind: Kind }>();
  return results.map(({ prio: _, kind, ...user }) => ({ kind, user: user as User }));
}

/** day25 is a sales email: it goes only to a user whose license is the free trial now (checked again at send time). */
export function eligible({ kind, user }: Due, now: number): boolean {
  if (kind !== 'day25') return true;
  const l = licenseOf(user, now);
  return l.plan === 'trial' && l.status === 'trial';
}

/** Whole days until the trial ends, rounded up, as /account counts them. */
export const daysLeft = (user: User, now: number) =>
  Math.max(0, Math.ceil((Date.parse(user.trial_started_at) + TRIAL_DAYS * DAY - now) / DAY));

/** The trial emails' sender; replies go to support@ (mail.ts REPLY_TO). */
export const FROM = 'shepetal <hello@shepetal.app>';

/** The email for one user: subject, text, HTML and the one-click unsubscribe headers (RFC 8058). */
export async function compose({ kind, user }: Due, secret: string, now: number) {
  const l = licenseOf(user, now);
  const unsubscribe = await unsubscribeUrl(user.id, secret);
  const mail = render(kind, copyFor(kind, { trial: l.plan === 'trial', daysLeft: daysLeft(user, now) }), unsubscribe);
  return {
    from: FROM,
    to: user.email,
    ...mail,
    headers: { 'List-Unsubscribe': `<${unsubscribe}>`, 'List-Unsubscribe-Post': 'List-Unsubscribe=One-Click' },
  };
}

/**
 * SES refused this one message for good: MessageRejected, or a recipient address it cannot send to. Anything else
 * (429, 5xx, a paused or suspended account, a wrong region, a malformed request, no answer, an error before SES was
 * called) is a fault of the setup, not of the email.
 */
export function refusedForGood(e: unknown): boolean {
  if (!(e instanceof SesError) || e.status !== 400) return false;
  if (e.type === 'MessageRejected') return true;
  return e.type === 'BadRequestException' && /address|recipient|destination|@domain/i.test(e.message);
}

/** A log line never carries an email address (SES's errors can echo them). */
const redact = (s: string) => s.replace(/[^\s"'<>()@:]+@[^\s"'<>(),]+/g, '<address>');

/**
 * One cron run. Never throws for one email: each outcome is logged and returned.
 * A message SES refused for good is marked failed and never tried again. Any other error releases the claim and stops
 * the run: a fault of the setup costs no email, and each goes out on a later run, once it is fixed, while its window
 * is open.
 */
export async function runLifecycle(
  env: LifecycleEnv,
  now = Date.now(),
  { fetchImpl = fetch, log = console.log }: { fetchImpl?: typeof fetch; log?: (...a: unknown[]) => void } = {},
): Promise<Outcome[]> {
  const on = env.LIFECYCLE_EMAILS === 'on';
  if (on && (!sesConfigured(env) || !env.AUTH_SECRET)) {
    log('lifecycle: LIFECYCLE_EMAILS is on, but SES or AUTH_SECRET is not set: nothing sent');
    return [];
  }
  // One more than a run sends, to tell when emails are waiting: a backlog that outgrows the runs loses emails whose
  // window closes, so it must show in the logs.
  const all = await due(env.DB, now, BATCH + 1);
  if (all.length > BATCH) log(`lifecycle: more than ${BATCH} emails due, ${BATCH} taken this run, the rest wait for the next runs`);
  const out: Outcome[] = [];
  for (const d of all.slice(0, BATCH)) {
    const o: Outcome = { kind: d.kind, user_id: d.user.id, result: 'skipped' };
    out.push(o);
    if (!eligible(d, now)) continue;
    if (!on) {
      o.result = 'would_send';
      continue;
    }
    // The claim: whoever inserts the row sends the email; anyone else skips it.
    const claim = await env.DB.prepare('INSERT INTO lifecycle_emails (user_id, kind) VALUES (?1, ?2) ON CONFLICT DO NOTHING')
      .bind(d.user.id, d.kind)
      .run();
    if (claim.meta.changes !== 1) continue;
    let id: string;
    try {
      id = await sesSend(env, await compose(d, env.AUTH_SECRET!, now), fetchImpl);
    } catch (e) {
      o.detail = redact((e as Error)?.message ?? String(e)).slice(0, 300);
      if (refusedForGood(e)) {
        // This one message: never sent again.
        await env.DB.prepare("UPDATE lifecycle_emails SET status = 'failed', error = ?3 WHERE user_id = ?1 AND kind = ?2")
          .bind(d.user.id, d.kind, o.detail)
          .run();
        o.result = 'failed';
        continue;
      }
      // The setup, not this email: release the claim and stop, so the rest are not spent on the same fault.
      await env.DB.prepare('DELETE FROM lifecycle_emails WHERE user_id = ?1 AND kind = ?2').bind(d.user.id, d.kind).run();
      o.result = 'retry';
      o.detail = `run stopped, nothing marked failed: ${o.detail}`;
      break;
    }
    await env.DB.prepare("UPDATE lifecycle_emails SET status = 'sent', sent_at = ?3, message_id = ?4 WHERE user_id = ?1 AND kind = ?2")
      .bind(d.user.id, d.kind, iso(Date.now()), id)
      .run();
    o.result = 'sent';
  }
  // User ids only: no email address goes into the Worker's logs.
  for (const o of out) log(`lifecycle: ${o.result} ${o.kind} user ${o.user_id}${o.detail ? `: ${o.detail}` : ''}`);
  return out;
}

// ---- Unsubscribe: /unsubscribe?u=<user id>&s=<HMAC-SHA256(AUTH_SECRET, "lifecycle-unsubscribe\n" + id), base64url>.

const b64url = (b: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

// Imported once per secret, not for every email of a run.
let unsubscribeKey: { secret: string; key: Promise<CryptoKey> } | null = null;

export async function unsubscribeSig(userId: number, secret: string): Promise<string> {
  if (unsubscribeKey?.secret !== secret) {
    const key = crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    unsubscribeKey = { secret, key };
  }
  return b64url(await crypto.subtle.sign('HMAC', await unsubscribeKey.key, new TextEncoder().encode(`lifecycle-unsubscribe\n${userId}`)));
}

export const unsubscribeUrl = async (userId: number, secret: string) =>
  `${SITE_URL}/unsubscribe?u=${userId}&s=${await unsubscribeSig(userId, secret)}`;

/** The user id a link names, if its signature is right (compared in constant time). */
export async function verifyUnsubscribe(params: URLSearchParams, secret: string | undefined): Promise<number | null> {
  const u = params.get('u') ?? '';
  const s = params.get('s') ?? '';
  if (!secret || !/^[1-9]\d{0,15}$/.test(u)) return null;
  const want = await unsubscribeSig(Number(u), secret);
  if (s.length !== want.length) return null;
  let diff = 0;
  for (let i = 0; i < want.length; i++) diff |= want.charCodeAt(i) ^ s.charCodeAt(i);
  return diff === 0 ? Number(u) : null;
}

const page = (title: string, body: string, status = 200) =>
  new Response(
    `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>${title}</title></head>
<body style="font-family:system-ui,sans-serif;max-width:32rem;margin:6rem auto;padding:0 1rem;line-height:1.5">
<h1>${title}</h1>
${body}
<p><a href="/">Back to shepetal</a></p></body></html>`,
    { status, headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' } },
  );

/**
 * GET and POST /unsubscribe, or null for any other request.
 * GET shows a button and changes nothing (mail scanners open links). POST unsubscribes: the button, and the
 * one-click POST mail apps send from List-Unsubscribe-Post (RFC 8058), which has no Origin and no cookie: the
 * signature in the URL is what authorizes it.
 */
export async function unsubscribeRoute(req: Request, env: { DB: D1Database; AUTH_SECRET?: string }): Promise<Response | null> {
  const url = new URL(req.url);
  if (url.pathname !== '/unsubscribe' || (req.method !== 'GET' && req.method !== 'POST')) return null;
  const id = await verifyUnsubscribe(url.searchParams, env.AUTH_SECRET);
  if (!id) return page('This link does not work', '<p>It may be cut short. Open it again from the email, or write to support@shepetal.app.</p>', 400);
  if (req.method === 'GET') {
    const action = `/unsubscribe?u=${id}&amp;s=${url.searchParams.get('s')}`;
    return page(
      'Unsubscribe from the trial emails',
      `<p>You will get no more emails about your shepetal trial. Receipts for anything you buy still come.</p>
<form method="post" action="${action}"><button type="submit" style="font:inherit;padding:.5rem 1rem">Unsubscribe</button></form>`,
    );
  }
  await env.DB.prepare('INSERT INTO email_unsubscribes (user_id) VALUES (?1) ON CONFLICT DO NOTHING').bind(id).run();
  return page('You are unsubscribed', '<p>You will get no more emails about your shepetal trial.</p>');
}

/** GET and POST /unsubscribe as worker.ts calls it (inside OpenNext's request context, before Next). */
export const unsubscribe = async (req: Request): Promise<Response> =>
  (await unsubscribeRoute(req, { DB: db(), AUTH_SECRET: process.env.AUTH_SECRET }))!;
