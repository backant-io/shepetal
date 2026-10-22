import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { sigv4 } from './ses';
import { db, useTestDb } from './test-db';
import {
  CONSENT_TEXT, IP_PER_HOUR, MAIL_EVERY_MIN, PAGE, confirm, normalEmail, sendConfirmation, sign, signup, sweep, unsubscribe, unsubscribePage,
  type WaitlistEnv,
} from './waitlist';

// The waitlist is answered by worker.ts without Next (10 ms of CPU on Workers Free), and it holds people's email
// addresses: what it must never do is take a signup from another site, store one without the box ticked, tell anyone
// whether an address is on the list, email an address more than the throttle allows, count anyone who did not click
// the link, or send a single email before Pavel switches WAITLIST_EMAILS on.

useTestDb();
beforeEach(() => db().exec('DELETE FROM waitlist'));
afterEach(() => vi.restoreAllMocks());

const ORIGIN = 'https://shepetal.app';
const SECRET = 'test-secret';
const T0 = Date.parse('2026-10-22T10:00:00Z');
const MIN = 60_000;

const env = (more: Partial<WaitlistEnv> = {}): WaitlistEnv => ({ DB: db(), AUTH_SECRET: SECRET, WAITLIST_EMAILS: 'off', ...more });

/** The confirmation emails the Worker would send after the answer (ctx.waitUntil), here collected and awaited. */
function mailbox() {
  const pending: Promise<unknown>[] = [];
  const sent: { to: string; text: string; headers: Record<string, string> }[] = [];
  vi.spyOn(console, 'log').mockImplementation((line: string) => {
    const m = JSON.parse(line);
    if (m.waitlist_email_not_sent) sent.push(m);
  });
  return { defer: (p: Promise<unknown>) => void pending.push(p), sent, flush: () => Promise.all(pending.splice(0)) };
}

const form = (fields: Record<string, string | string[]>, headers: Record<string, string> = {}) => {
  const body = new URLSearchParams();
  for (const [k, v] of Object.entries(fields)) for (const x of [v].flat()) body.append(k, x);
  return new Request(`${ORIGIN}/api/waitlist`, {
    method: 'POST',
    headers: { origin: ORIGIN, 'content-type': 'application/x-www-form-urlencoded', 'cf-connecting-ip': '203.0.113.7', ...headers },
    body,
  });
};
const good = (email = 'ada@example.com', platform: string | string[] = 'windows') => ({ email, platform, consent: 'yes' });
const row = (email = 'ada@example.com') => db().prepare('SELECT * FROM waitlist WHERE email = ?1').bind(email).first<Record<string, string | null>>();
const count = async () => (await db().prepare('SELECT COUNT(*) AS n FROM waitlist').first<{ n: number }>())!.n;
const linkIn = (text: string, path: string) => new URL(text.match(new RegExp(`${ORIGIN}${path}\\?t=\\S+`))![0]);

describe('POST /api/waitlist', () => {
  it('stores a signup with what the box said, and answers with the thanks page', async () => {
    const m = mailbox();
    const res = await signup(form(good('  Ada@Example.com ', ['linux', 'iphone', 'linux', 'android'])), env(), m.defer, T0);
    expect(res.status).toBe(303);
    expect(res.headers.get('location')).toBe(PAGE.thanks);
    const r = (await row())!;
    expect(r.platforms).toBe('iphone,linux');
    expect(r.consent_text).toBe(CONSENT_TEXT);
    expect(r.confirmed_at).toBeNull();
    // The IP address itself is never stored.
    expect(JSON.stringify(r)).not.toContain('203.0.113.7');
    await m.flush();
    expect(m.sent.map((x) => x.to)).toEqual(['ada@example.com']);
  });

  // A page on another site could otherwise sign up any address it likes, from its visitors' browsers.
  it('refuses a cross-site POST, and one with no Origin', async () => {
    const m = mailbox();
    for (const origin of ['https://evil.example', 'null', 'https://shepetal.app.evil.example', 'http://shepetal.app']) {
      const res = await signup(form(good(), { origin }), env(), m.defer, T0);
      expect(res.status, origin).toBe(403);
    }
    const bare = form(good());
    bare.headers.delete('origin');
    expect((await signup(bare, env(), m.defer, T0)).status).toBe(403);
    expect(await count()).toBe(0);
    await m.flush();
    expect(m.sent).toEqual([]);
  });

  // Consent under GDPR Art. 6(1)(a) is the ticked box, nothing else.
  it('refuses a signup without the consent box ticked, without a platform, or with a bad address', async () => {
    const m = mailbox();
    for (const fields of <Record<string, string>[]>[
      { email: 'ada@example.com', platform: 'windows' },
      { email: 'ada@example.com', platform: 'windows', consent: 'on' },
      { email: 'ada@example.com', consent: 'yes' },
      { email: 'ada@example.com', platform: 'android', consent: 'yes' },
      { email: 'ada@', platform: 'windows', consent: 'yes' },
      { email: 'ada@example.com, bob@example.com', platform: 'windows', consent: 'yes' },
    ]) {
      const res = await signup(form(fields), env(), m.defer, T0);
      expect(res.headers.get('location'), JSON.stringify(fields)).toBe(PAGE.check);
    }
    expect(await count()).toBe(0);
    await m.flush();
    expect(m.sent).toEqual([]);
  });

  // Whether an address is on the list is nobody's business: the answer is the same, byte for byte, and the email goes
  // out after it, so it takes no longer either.
  it('answers a new, a pending, a confirmed and a throttled address, and a failed database, exactly alike', async () => {
    const m = mailbox();
    const answer = async (r: Response) => [r.status, [...r.headers], await r.text()];
    const fresh = await answer(await signup(form(good('new@example.com')), env(), m.defer, T0));
    await signup(form(good('old@example.com')), env(), m.defer, T0);
    expect(await answer(await signup(form(good('old@example.com')), env(), m.defer, T0 + MIN))).toEqual(fresh);
    await db().prepare("UPDATE waitlist SET confirmed_at = '2026-10-01T00:00:00.000Z' WHERE email = 'old@example.com'").run();
    expect(await answer(await signup(form(good('old@example.com')), env(), m.defer, T0 + 2 * MIN))).toEqual(fresh);
    for (let i = 0; i < IP_PER_HOUR; i++) await signup(form(good(`t${i}@example.com`), { 'cf-connecting-ip': '192.0.2.1' }), env(), m.defer, T0);
    expect(await answer(await signup(form(good('t@example.com'), { 'cf-connecting-ip': '192.0.2.1' }), env(), m.defer, T0))).toEqual(fresh);
    expect(await row('t@example.com')).toBeNull();
    expect(await answer(await signup(form(good('x@example.com')), env({ DB: brokenDb() }), m.defer, T0))).toEqual(fresh);
  });

  // Each confirmation email goes to whatever address was typed, so one IP must not be able to send many, and no one
  // address may get many.
  it('throttles: at most IP_PER_HOUR signups an hour from one IP, and one email per address per MAIL_EVERY_MIN minutes', async () => {
    const m = mailbox();
    for (let i = 0; i <= IP_PER_HOUR; i++) await signup(form(good(`p${i}@example.com`)), env(), m.defer, T0 + i * 1000);
    expect(await count()).toBe(IP_PER_HOUR);
    expect(await row(`p${IP_PER_HOUR}@example.com`)).toBeNull();
    // Another IP is not held back, and the first one is free again after an hour.
    await signup(form(good('q@example.com'), { 'cf-connecting-ip': '198.51.100.1' }), env(), m.defer, T0 + MIN);
    await signup(form(good('r@example.com')), env(), m.defer, T0 + 61 * MIN);
    expect(await count()).toBe(IP_PER_HOUR + 2);

    await m.flush();
    m.sent.length = 0;
    const ip = { 'cf-connecting-ip': '192.0.2.9' };
    await signup(form(good('s@example.com'), ip), env(), m.defer, T0);
    await signup(form(good('s@example.com', 'linux'), ip), env(), m.defer, T0 + (MAIL_EVERY_MIN - 1) * MIN);
    await m.flush();
    expect(m.sent.map((x) => x.to)).toEqual(['s@example.com']);
    // The pending row still takes the new choice.
    expect((await row('s@example.com'))!.platforms).toBe('linux');
    await signup(form(good('s@example.com', 'linux'), ip), env(), m.defer, T0 + (MAIL_EVERY_MIN + 1) * MIN);
    await m.flush();
    expect(m.sent.map((x) => x.to)).toEqual(['s@example.com', 's@example.com']);
  });

  it('sends a confirmed address no email for the same choice again', async () => {
    const m = mailbox();
    await signup(form(good()), env(), m.defer, T0);
    await m.flush();
    await confirm(new Request(linkIn(m.sent[0].text, '/api/waitlist/confirm')), env(), T0 + MIN);
    await signup(form(good()), env(), m.defer, T0 + 60 * MIN);
    await m.flush();
    expect(m.sent).toHaveLength(1);
  });
});

/** A D1 that fails every query (the table missing, an outage). */
function brokenDb(): D1Database {
  return { prepare: () => { throw new Error('no such table: waitlist'); } } as unknown as D1Database;
}

describe('the confirmation link (double opt-in)', () => {
  async function signedUp(email = 'ada@example.com', platform: string | string[] = 'windows', at = T0) {
    const m = mailbox();
    await signup(form(good(email, platform)), env(), m.defer, at);
    await m.flush();
    return m.sent.at(-1)!;
  }

  it('counts an address only once its link is clicked, and sends unsubscribe headers for one click (RFC 8058)', async () => {
    const mail = await signedUp('ada@example.com', ['windows', 'iphone']);
    expect(mail.text).toContain('shepetal comes to iPhone or Windows');
    expect(mail.headers['List-Unsubscribe-Post']).toBe('List-Unsubscribe=One-Click');
    expect(mail.headers['List-Unsubscribe']).toMatch(/^<https:\/\/shepetal\.app\/api\/waitlist\/unsubscribe\?t=[\w-]+\.[\w-]+>$/);
    expect((await row())!.confirmed_at).toBeNull();
    const res = await confirm(new Request(linkIn(mail.text, '/api/waitlist/confirm')), env(), T0 + MIN);
    expect(res.headers.get('location')).toBe(PAGE.confirmed);
    expect((await row())!.confirmed_at).toBe(new Date(T0 + MIN).toISOString());
  });

  // Anyone can type any address into the form; only the person who reads that inbox may confirm it.
  it('refuses a link that is not signed with AUTH_SECRET, was changed, is an unsubscribe link, or is over 7 days old', async () => {
    const mail = await signedUp();
    const link = linkIn(mail.text, '/api/waitlist/confirm');
    const t = link.searchParams.get('t')!;
    const [payload, sig] = t.split('.');
    const forged = Buffer.from(JSON.stringify({ k: 'c', e: 'ada@example.com', p: ['linux', 'windows'], t: T0 })).toString('base64url');
    const bad = [
      '',
      'garbage',
      `${payload}.${sig.slice(0, -1)}${sig.endsWith('A') ? 'B' : 'A'}`,
      `${forged}.${sig}`,
      await sign('another-secret', { k: 'c', e: 'ada@example.com', p: ['windows'], t: T0 }),
      await sign(SECRET, { k: 'u', e: 'ada@example.com' }),
    ];
    for (const x of bad) {
      const res = await confirm(new Request(`${ORIGIN}/api/waitlist/confirm?t=${x}`), env(), T0 + MIN);
      expect(res.headers.get('location'), x).toBe(PAGE.badLink);
    }
    expect((await confirm(new Request(link), env(), T0 + 7 * 86_400_000)).headers.get('location')).toBe(PAGE.badLink);
    expect((await row())!.confirmed_at).toBeNull();
  });

  // Unsubscribing has to stick: a confirmation email still in the inbox must not undo it.
  it('never lets a link from before an unsubscribe subscribe again; a new signup’s link does', async () => {
    const first = await signedUp();
    await confirm(new Request(linkIn(first.text, '/api/waitlist/confirm')), env(), T0 + MIN);
    await unsubscribe(new Request(linkIn(first.text, '/api/waitlist/unsubscribe'), { method: 'POST', body: 'List-Unsubscribe=One-Click' }), env(), T0 + 2 * MIN);
    const again = await confirm(new Request(linkIn(first.text, '/api/waitlist/confirm')), env(), T0 + 3 * MIN);
    expect(again.headers.get('location')).toBe(PAGE.badLink);
    expect((await row())!.unsubscribed_at).not.toBeNull();

    const second = await signedUp('ada@example.com', 'linux', T0 + 60 * MIN);
    // Until the new link is clicked, the old choice stands and the address does not count.
    expect((await row())!.platforms).toBe('windows');
    await confirm(new Request(linkIn(second.text, '/api/waitlist/confirm')), env(), T0 + 61 * MIN);
    const r = (await row())!;
    expect([r.platforms, r.unsubscribed_at]).toEqual(['linux', null]);
  });
});

describe('unsubscribe', () => {
  it('unsubscribes on a mail app’s one-click POST with no Origin, on the page’s button, but never on a GET', async () => {
    const m = mailbox();
    await signup(form(good()), env(), m.defer, T0);
    await m.flush();
    const link = linkIn(m.sent[0].text, '/api/waitlist/unsubscribe');
    // Link checkers open every link in an email: the GET only shows the page with the button.
    const page = unsubscribePage(new Request(link));
    expect(page.headers.get('location')).toBe(`${PAGE.unsubscribe}?t=${link.searchParams.get('t')}`);
    expect((await row())!.unsubscribed_at).toBeNull();

    const oneClick = await unsubscribe(new Request(link, { method: 'POST', body: 'List-Unsubscribe=One-Click' }), env(), T0 + MIN);
    expect(oneClick.status).toBe(200);
    expect((await row())!.unsubscribed_at).toBe(new Date(T0 + MIN).toISOString());

    const button = await unsubscribe(
      new Request(`${ORIGIN}/api/waitlist/unsubscribe`, { method: 'POST', body: new URLSearchParams({ t: link.searchParams.get('t')! }) }),
      env(),
      T0 + 2 * MIN,
    );
    expect(button.headers.get('location')).toBe(PAGE.unsubscribed);
    // The first unsubscribe is the one recorded.
    expect((await row())!.unsubscribed_at).toBe(new Date(T0 + MIN).toISOString());
    const forged = await unsubscribe(new Request(`${ORIGIN}/api/waitlist/unsubscribe?t=${await sign('x', { k: 'u', e: 'b@example.com' })}`, { method: 'POST' }), env());
    expect(forged.headers.get('location')).toBe(PAGE.badLink);
  });
});

describe('WAITLIST_EMAILS, the kill switch', () => {
  // Off (the default in wrangler.toml) means store and log: no email leaves before Pavel says so.
  it('off: stores the signup and logs the email, and never calls SES', async () => {
    const fetch = vi.fn();
    vi.stubGlobal('fetch', fetch);
    try {
      const m = mailbox();
      const keys = { SES_ACCESS_KEY_ID: 'AKIDEXAMPLE', SES_SECRET_ACCESS_KEY: 'secret', SES_REGION: 'eu-central-1' };
      for (const WAITLIST_EMAILS of ['off', undefined, 'ON', 'yes']) {
        await signup(form(good(`${WAITLIST_EMAILS}@example.com`)), env({ ...keys, WAITLIST_EMAILS }), m.defer, T0);
      }
      await m.flush();
      expect(fetch).not.toHaveBeenCalled();
      expect(m.sent).toHaveLength(4);
      expect(await count()).toBe(4);
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it('on: sends through SES v2 in eu-central-1 from hello@, Reply-To support@, signed with SigV4', async () => {
    const fetch = vi.fn(async () => new Response('{"MessageId":"x"}'));
    vi.stubGlobal('fetch', fetch);
    try {
      await sendConfirmation(
        env({ WAITLIST_EMAILS: 'on', SES_ACCESS_KEY_ID: 'AKIDEXAMPLE', SES_SECRET_ACCESS_KEY: 'secret', SES_REGION: 'eu-central-1' }),
        ORIGIN, 'ada@example.com', ['linux'], T0,
      );
      expect(fetch).toHaveBeenCalledTimes(1);
      const [url, init] = fetch.mock.calls[0] as unknown as [string, RequestInit & { headers: Record<string, string> }];
      expect(url).toBe('https://email.eu-central-1.amazonaws.com/v2/email/outbound-emails');
      expect(init.headers.authorization).toMatch(/^AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE\/20261022\/eu-central-1\/ses\/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=[0-9a-f]{64}$/);
      const body = JSON.parse(init.body as string);
      expect(body.FromEmailAddress).toBe('shepetal <hello@shepetal.app>');
      expect(body.ReplyToAddresses).toEqual(['support@shepetal.app']);
      expect(body.Destination).toEqual({ ToAddresses: ['ada@example.com'] });
      expect(body.Content.Simple.Headers.map((h: { Name: string }) => h.Name)).toEqual(['List-Unsubscribe', 'List-Unsubscribe-Post']);
    } finally {
      vi.unstubAllGlobals();
    }
  });
});

describe('SigV4', () => {
  // AWS's own test suite (aws-sig-v4-test-suite, post-vanilla): a wrong canonical request fails here, not in production.
  it('matches the post-vanilla vector', async () => {
    const h = await sigv4({
      method: 'POST', url: 'https://example.amazonaws.com/', body: '', region: 'us-east-1', service: 'service',
      key: 'AKIDEXAMPLE', secret: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY', now: new Date('2015-08-30T12:36:00Z'),
    });
    expect(h.authorization).toBe(
      'AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b',
    );
  });
});

describe('the sweep and the addresses', () => {
  it('deletes what is not confirmed and subscribed 29 days after its last signup, and keeps every confirmed address', async () => {
    const m = mailbox();
    for (const e of ['pending', 'confirmed', 'gone']) await signup(form(good(`${e}@example.com`), { 'cf-connecting-ip': e }), env(), m.defer, T0);
    await db().prepare("UPDATE waitlist SET confirmed_at = ?1 WHERE email IN ('confirmed@example.com', 'gone@example.com')").bind(new Date(T0).toISOString()).run();
    await db().prepare("UPDATE waitlist SET unsubscribed_at = ?1 WHERE email = 'gone@example.com'").bind(new Date(T0).toISOString()).run();
    expect(await sweep(db(), T0 + 28 * 86_400_000)).toBe(0);
    expect(await sweep(db(), T0 + 29 * 86_400_000 + 1)).toBe(2);
    expect((await db().prepare('SELECT email FROM waitlist').all()).results).toEqual([{ email: 'confirmed@example.com' }]);
  });

  it('takes plain addresses only', () => {
    expect(normalEmail(' Ada.L+shepetal@Example.co.uk ')).toBe('ada.l+shepetal@example.co.uk');
    for (const bad of [null, '', 'ada', 'ada@localhost', 'a b@example.com', '.ada@example.com', 'ada.@example.com', 'a..b@example.com', 'ada@-x.com', '"a"@example.com', `${'a'.repeat(65)}@example.com`])
      expect(normalEmail(bad), String(bad)).toBeNull();
  });

  it('is a new migration, 0005 (0004 is taken by another change)', () => {
    const sql = readFileSync(join(__dirname, '..', '..', 'migrations', '0005_waitlist.sql'), 'utf8');
    for (const col of ['email', 'platforms', 'created_at', 'confirmed_at', 'unsubscribed_at', 'consent_text', 'ip_hash']) expect(sql).toContain(`  ${col} `);
  });
});
