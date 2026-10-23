import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { copyProblems } from './brand-copy';
import { db, useTestDb } from './test-db';

// The waitlist is answered by worker.ts without Next (10 ms of CPU on Workers Free), and it holds people's email
// addresses: what it must never do is take a signup from another site, store one without the box ticked, tell anyone
// whether an address is on the list, email an address more than the throttle allows, count anyone who did not click
// the link, put an address in a URL or a log line, or do anything at all before Pavel switches WAITLIST on.

const mail = vi.hoisted(() => ({ sendMail: vi.fn(async (_to: string, _subject: string, _text: string) => {}) }));
vi.mock('./mail', () => mail);
const cf = vi.hoisted(() => ({ env: {} as Record<string, unknown>, ctx: { waitUntil: (_: Promise<unknown>) => {} } }));
vi.mock('@opennextjs/cloudflare', () => ({ getCloudflareContext: () => cf }));
import type { WaitlistEnv } from './waitlist';
const { CONSENT_TEXT, IP_PER_HOUR, MAIL_EVERY_MIN, MAIL_PER_HOUR, PAGE, confirm, normalEmail, scrub, sign, signup, sweep, unsubscribe, unsubscribePage } =
  await import('./waitlist');

useTestDb();
const logged: string[] = [];
beforeEach(async () => {
  await db().exec('DELETE FROM waitlist');
  mail.sendMail.mockClear();
  logged.length = 0;
  for (const level of ['log', 'info', 'warn', 'error', 'debug'] as const)
    vi.spyOn(console, level).mockImplementation((...a: unknown[]) => void logged.push(a.map(String).join(' ')));
});
// No test may leave an address (or anything of one) in a log line.
afterEach(() => {
  expect(logged.join('\n')).not.toMatch(/@|example\.com/);
  vi.restoreAllMocks();
});

const ORIGIN = 'https://shepetal.app';
const SECRET = 'test-secret';
const T0 = Date.parse('2026-10-22T10:00:00Z');
const MIN = 60_000;

const env = (more: Partial<WaitlistEnv> = {}): WaitlistEnv => ({ DB: db(), AUTH_SECRET: SECRET, WAITLIST: 'on', ...more });

/** The confirmation emails the Worker sends after the answer (ctx.waitUntil), here collected and awaited. */
function mailbox() {
  const pending: Promise<unknown>[] = [];
  const sent = () => mail.sendMail.mock.calls.map(([to, subject, text]) => ({ to, subject, text }));
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
const oneClick = (link: URL) => new Request(link, { method: 'POST', body: 'List-Unsubscribe=One-Click' });

describe('WAITLIST off (the default in wrangler.toml)', () => {
  it('is off in wrangler.toml, and that is what the tests and the build read', () => {
    const toml = readFileSync(join(__dirname, '..', '..', 'wrangler.toml'), 'utf8');
    expect(toml).toMatch(/^WAITLIST = "off"$/m);
    expect(process.env.WAITLIST).toBe('off');
  });

  it('POST /api/waitlist and the confirmation link answer 404: nothing read, stored, sent or logged', async () => {
    const m = mailbox();
    const DB = { prepare: vi.fn(), batch: vi.fn(), exec: vi.fn() } as unknown as D1Database;
    for (const WAITLIST of [undefined, 'off', 'ON', 'yes', 'true', '']) {
      const req = form(good());
      const res = await signup(req, env({ WAITLIST, DB }), m.defer, T0);
      expect(res.status, String(WAITLIST)).toBe(404);
      expect(req.bodyUsed).toBe(false);
      const t = await sign(SECRET, { k: 'c', i: 'x', p: ['windows'], t: T0 });
      expect((await confirm(new Request(`${ORIGIN}/api/waitlist/confirm?t=${t}`), env({ WAITLIST, DB }), T0)).status).toBe(404);
    }
    await m.flush();
    expect(DB.prepare).not.toHaveBeenCalled();
    expect(DB.batch).not.toHaveBeenCalled();
    expect(mail.sendMail).not.toHaveBeenCalled();
    expect(logged).toEqual([]);
  });

  // What worker.ts calls (NATIVE), with the env of the deployed Worker: wrangler.toml's WAITLIST = "off".
  it('the routes worker.ts calls answer 404 with the env as deployed', async () => {
    const DB = { prepare: vi.fn(), batch: vi.fn() };
    cf.env = { DB, AUTH_SECRET: SECRET, WAITLIST: process.env.WAITLIST };
    const { POST } = await import('@/app/api/waitlist/route');
    const { GET } = await import('@/app/api/waitlist/confirm/route');
    expect((await POST(form(good()))).status).toBe(404);
    expect((await GET(new Request(`${ORIGIN}/api/waitlist/confirm?t=${await sign(SECRET, { k: 'c', i: 'x', p: ['linux'], t: Date.now() })}`))).status).toBe(404);
    expect(DB.prepare).not.toHaveBeenCalled();
    expect(DB.batch).not.toHaveBeenCalled();
    expect(mail.sendMail).not.toHaveBeenCalled();
  });

  // Turned off after it was on: a person who got an email can still leave.
  it('still unsubscribes, which can only delete', async () => {
    const m = mailbox();
    await signup(form(good()), env(), m.defer, T0);
    await m.flush();
    const res = await unsubscribe(oneClick(linkIn(m.sent()[0].text, '/api/waitlist/unsubscribe')), env({ WAITLIST: 'off' }));
    expect(res.status).toBe(200);
    expect(await count()).toBe(0);
  });
});

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
    expect(r.id).toMatch(/^[\w-]{22}$/);
    // The IP address itself is never stored.
    expect(JSON.stringify(r)).not.toContain('203.0.113.7');
    await m.flush();
    expect(m.sent().map((x) => x.to)).toEqual(['ada@example.com']);
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
    expect(mail.sendMail).not.toHaveBeenCalled();
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
      { email: `${'a'.repeat(3000)}@example.com`, platform: 'windows', consent: 'yes' },
    ]) {
      const res = await signup(form(fields), env(), m.defer, T0);
      expect(res.headers.get('location'), JSON.stringify(fields).slice(0, 80)).toBe(PAGE.check);
    }
    expect(await count()).toBe(0);
    await m.flush();
    expect(mail.sendMail).not.toHaveBeenCalled();
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
    // The failure is logged, without the address.
    expect(logged.some((l) => l.startsWith('waitlist: signup failed'))).toBe(true);
  });

  // Each confirmation email goes to whatever address was typed, so one IP must not be able to send many, no one
  // address may get many, and many IPs together are capped too.
  it('throttles: IP_PER_HOUR signups an hour from one IP, one email per address per MAIL_EVERY_MIN minutes, MAIL_PER_HOUR in all', async () => {
    const m = mailbox();
    for (let i = 0; i <= IP_PER_HOUR; i++) await signup(form(good(`p${i}@example.com`)), env(), m.defer, T0 + i * 1000);
    expect(await count()).toBe(IP_PER_HOUR);
    expect(await row(`p${IP_PER_HOUR}@example.com`)).toBeNull();
    // Another IP is not held back, and the first one is free again after an hour.
    await signup(form(good('q@example.com'), { 'cf-connecting-ip': '198.51.100.1' }), env(), m.defer, T0 + MIN);
    await signup(form(good('r@example.com')), env(), m.defer, T0 + 61 * MIN);
    expect(await count()).toBe(IP_PER_HOUR + 2);

    await m.flush();
    mail.sendMail.mockClear();
    const ip = { 'cf-connecting-ip': '192.0.2.9' };
    await signup(form(good('s@example.com'), ip), env(), m.defer, T0);
    await signup(form(good('s@example.com', 'linux'), ip), env(), m.defer, T0 + (MAIL_EVERY_MIN - 1) * MIN);
    await m.flush();
    expect(m.sent().map((x) => x.to)).toEqual(['s@example.com']);
    // The pending row still takes the new choice.
    expect((await row('s@example.com'))!.platforms).toBe('linux');
    await signup(form(good('s@example.com', 'linux'), ip), env(), m.defer, T0 + (MAIL_EVERY_MIN + 1) * MIN);
    await m.flush();
    expect(m.sent().map((x) => x.to)).toEqual(['s@example.com', 's@example.com']);

    // The hourly cap on all confirmation emails.
    await db().exec('DELETE FROM waitlist');
    mail.sendMail.mockClear();
    const sent = new Date(T0 + 100 * MIN).toISOString();
    await db().batch(
      Array.from({ length: MAIL_PER_HOUR }, (_, i) =>
        db().prepare("INSERT INTO waitlist (id, email, platforms, created_at, consent_text, ip_hash, last_request_at, last_mail_at) VALUES (?1, ?2, 'linux', ?3, '', ?1, ?3, ?3)").bind(`id${i}`, `c${i}@example.com`, sent),
      ),
    );
    await signup(form(good('late@example.com'), { 'cf-connecting-ip': '192.0.2.77' }), env(), m.defer, T0 + 101 * MIN);
    await m.flush();
    expect(mail.sendMail).not.toHaveBeenCalled();
    expect((await row('late@example.com'))!.last_mail_at).toBeNull();
  });

  it('sends a confirmed address no email for the same choice again', async () => {
    const m = mailbox();
    await signup(form(good()), env(), m.defer, T0);
    await m.flush();
    await confirm(new Request(linkIn(m.sent()[0].text, '/api/waitlist/confirm')), env(), T0 + MIN);
    await signup(form(good()), env(), m.defer, T0 + 60 * MIN);
    await m.flush();
    expect(mail.sendMail).toHaveBeenCalledTimes(1);
  });

  // mail.ts throws while SES is not set up, and SES's own errors can quote the address.
  it('logs a failed email without the address', async () => {
    mail.sendMail.mockRejectedValueOnce(new Error('SES 400: {"message":"Email address is not verified: ada@example.com"}'));
    const m = mailbox();
    await signup(form(good()), env(), m.defer, T0);
    await m.flush();
    expect(logged).toEqual(['waitlist: confirmation email failed SES 400: {"message":"Email address is not verified: <email>"}']);
  });
});

/** A D1 that fails every query (the table missing, an outage), quoting the address as a driver might. */
function brokenDb(): D1Database {
  const fail = () => { throw new Error('D1_ERROR: no such table: waitlist (x@example.com)'); };
  return { prepare: () => ({ bind: fail }), batch: fail } as unknown as D1Database;
}

describe('the confirmation email and its link (double opt-in)', () => {
  async function signedUp(email = 'ada@example.com', platform: string | string[] = 'windows', at = T0) {
    const m = mailbox();
    mail.sendMail.mockClear();
    await signup(form(good(email, platform), { 'cf-connecting-ip': `198.51.100.${at % 250}` }), env(), m.defer, at);
    await m.flush();
    return m.sent().at(-1)!;
  }

  it('says what the address is for, and has a link that unsubscribes', async () => {
    const m = await signedUp('ada@example.com', ['windows', 'iphone']);
    expect(m.subject).toBe('Confirm your email for the shepetal waitlist');
    expect(m.text).toContain('shepetal comes to iPhone or Windows');
    expect(m.text).toContain('we only use your address to send you one email when shepetal comes to a platform you chose.');
    expect(m.text).toMatch(/Unsubscribe and delete your address: https:\/\/shepetal\.app\/api\/waitlist\/unsubscribe\?t=[\w-]+\.[\w-]+/);
    // The links carry random tokens: only the words are copy.
    expect(copyProblems(`${m.subject}\n${m.text.replace(/https:\/\/\S+/g, '<link>')}`)).toEqual([]);
  });

  // The request logs keep every URL: the address must not be in one, not even encoded.
  it('carries the row id in its links, never the address', async () => {
    const m = await signedUp();
    for (const path of ['/api/waitlist/confirm', '/api/waitlist/unsubscribe']) {
      const t = linkIn(m.text, path).searchParams.get('t')!;
      const payload = Buffer.from(t.split('.')[0], 'base64url').toString();
      expect(payload).toContain((await row())!.id);
      expect(payload).not.toMatch(/ada|example/);
    }
  });

  it('counts an address only once its link is clicked', async () => {
    const m = await signedUp();
    expect((await row())!.confirmed_at).toBeNull();
    const res = await confirm(new Request(linkIn(m.text, '/api/waitlist/confirm')), env(), T0 + MIN);
    expect(res.headers.get('location')).toBe(PAGE.confirmed);
    expect((await row())!.confirmed_at).toBe(new Date(T0 + MIN).toISOString());
  });

  // Anyone can type any address into the form; only the person who reads that inbox may confirm it.
  it('refuses a link that is not signed with AUTH_SECRET, was changed, is an unsubscribe link, or is over 7 days old', async () => {
    const m = await signedUp();
    const link = linkIn(m.text, '/api/waitlist/confirm');
    const [payload, sig] = link.searchParams.get('t')!.split('.');
    const id = (await row())!.id!;
    const forged = Buffer.from(JSON.stringify({ k: 'c', i: id, p: ['linux', 'windows'], t: T0 })).toString('base64url');
    const bad = [
      '',
      'garbage',
      `${payload}.${sig.slice(0, -1)}${sig.endsWith('A') ? 'B' : 'A'}`,
      `${forged}.${sig}`,
      await sign('another-secret', { k: 'c', i: id, p: ['windows'], t: T0 }),
      await sign(SECRET, { k: 'u', i: id }),
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
    await unsubscribe(oneClick(linkIn(first.text, '/api/waitlist/unsubscribe')), env());
    expect(await row()).toBeNull();

    const second = await signedUp('ada@example.com', 'linux', T0 + 60 * MIN);
    const again = await confirm(new Request(linkIn(first.text, '/api/waitlist/confirm')), env(), T0 + 61 * MIN);
    expect(again.headers.get('location')).toBe(PAGE.badLink);
    expect((await row())!.confirmed_at).toBeNull();
    await confirm(new Request(linkIn(second.text, '/api/waitlist/confirm')), env(), T0 + 62 * MIN);
    const r = (await row())!;
    expect([r.platforms, r.confirmed_at]).toEqual(['linux', new Date(T0 + 62 * MIN).toISOString()]);
  });
});

describe('unsubscribe', () => {
  it('deletes the address on a mail app’s one-click POST with no Origin, or on the page’s button, but never on a GET', async () => {
    const m = mailbox();
    await signup(form(good()), env(), m.defer, T0);
    await signup(form(good('bob@example.com'), { 'cf-connecting-ip': '192.0.2.50' }), env(), m.defer, T0);
    await m.flush();
    const [ada, bob] = m.sent().map((x) => linkIn(x.text, '/api/waitlist/unsubscribe'));
    // Link checkers open every link in an email: the GET only shows the page with the button.
    const page = unsubscribePage(new Request(ada));
    expect(page.headers.get('location')).toBe(`${PAGE.unsubscribe}?t=${ada.searchParams.get('t')}`);
    expect(await count()).toBe(2);

    expect((await unsubscribe(oneClick(ada), env())).status).toBe(200);
    expect(await row()).toBeNull();
    const button = await unsubscribe(
      new Request(`${ORIGIN}/api/waitlist/unsubscribe`, { method: 'POST', body: new URLSearchParams({ t: bob.searchParams.get('t')! }) }),
      env(),
    );
    expect(button.headers.get('location')).toBe(PAGE.unsubscribed);
    expect(await count()).toBe(0);
    const forged = await unsubscribe(new Request(`${ORIGIN}/api/waitlist/unsubscribe?t=${await sign('x', { k: 'u', i: 'y' })}`, { method: 'POST' }), env());
    expect(forged.headers.get('location')).toBe(PAGE.badLink);
  });
});

describe('the sweep, the addresses and the migration', () => {
  it('deletes what is not confirmed 29 days after its last signup, and keeps every confirmed address', async () => {
    const m = mailbox();
    for (const e of ['pending', 'confirmed']) await signup(form(good(`${e}@example.com`), { 'cf-connecting-ip': e }), env(), m.defer, T0);
    await db().prepare("UPDATE waitlist SET confirmed_at = ?1 WHERE email = 'confirmed@example.com'").bind(new Date(T0).toISOString()).run();
    expect(await sweep(db(), T0 + 28 * 86_400_000)).toBe(0);
    expect(await sweep(db(), T0 + 29 * 86_400_000 + 1)).toBe(1);
    expect((await db().prepare('SELECT email FROM waitlist').all()).results).toEqual([{ email: 'confirmed@example.com' }]);
  });

  it('takes plain addresses only', () => {
    expect(normalEmail(' Ada.L+shepetal@Example.co.uk ')).toBe('ada.l+shepetal@example.co.uk');
    for (const bad of [null, '', 'ada', 'ada@localhost', 'a b@example.com', '.ada@example.com', 'ada.@example.com', 'a..b@example.com', 'ada@-x.com', '"a"@example.com', `${'a'.repeat(65)}@example.com`])
      expect(normalEmail(bad), String(bad)).toBeNull();
  });

  it('scrubs every address out of what it logs', () => {
    expect(scrub(new Error('to <Ada.L+x@Example.co.uk>, b@c.de; "d@e.f"'))).toBe('to <<email>>, <email>; "<email>"');
    expect(scrub('plain')).toBe('plain');
  });

  // 0005 and 0006 belong to other branches (0006: feat/lifecycle-emails); release has 0001 to 0004 and 0007.
  it('is migration 0008, the only one about the waitlist, and touches nothing another migration made', () => {
    const dir = join(__dirname, '..', '..', 'migrations');
    expect(readdirSync(dir).filter((f) => f.includes('waitlist'))).toEqual(['0008_waitlist.sql']);
    const sql = readFileSync(join(dir, '0008_waitlist.sql'), 'utf8').replace(/--.*$/gm, '');
    const statements = sql.split(';').map((s) => s.trim().replace(/\s+/g, ' ')).filter(Boolean);
    expect(statements.map((s) => s.match(/^CREATE (TABLE waitlist|INDEX \w+ ON waitlist) /)?.[1])).toEqual(['TABLE waitlist', 'INDEX waitlist_ip ON waitlist', 'INDEX waitlist_mail ON waitlist']);
    for (const col of ['id', 'email', 'platforms', 'created_at', 'confirmed_at', 'consent_text', 'ip_hash', 'last_request_at', 'last_mail_at']) expect(sql).toContain(`  ${col} `);
  });
});
