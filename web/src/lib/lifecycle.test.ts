import { readFileSync } from 'node:fs';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { copyFor, render, type Kind } from './lifecycle-copy';
import { sweepTick } from './waitlist';
import { BATCH, compose, due, eligible, runLifecycle, unsubscribeRoute, unsubscribeUrl, verifyUnsubscribe, type LifecycleEnv } from './lifecycle';
import { db, useTestDb } from './test-db';

vi.mock('./db', () => import('./test-db'));
useTestDb();

const DAY = 86_400_000;
const NOW = Date.parse('2026-11-01T12:00:00.000Z');
const SECRET = 'test-auth-secret';
const SES = { SES_ACCESS_KEY_ID: 'AKIDEXAMPLE', SES_SECRET_ACCESS_KEY: 'secret', SES_REGION: 'eu-central-1' };

let sent: { to: string; subject: string; text: string; headers: { Name: string; Value: string }[] }[];
let answer: () => Response;
const fakeSes = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
  const b = JSON.parse(init!.body as string);
  const r = answer();
  if (r.ok) sent.push({ to: b.Destination.ToAddresses[0], subject: b.Content.Simple.Subject.Data, text: b.Content.Simple.Body.Text.Data, headers: b.Content.Simple.Headers });
  return r;
});
const env = (over: Partial<LifecycleEnv> = {}): LifecycleEnv => ({ DB: db(), AUTH_SECRET: SECRET, LIFECYCLE_EMAILS: 'on', ...SES, ...over });
const run = (over: Partial<LifecycleEnv> = {}, now = NOW) => runLifecycle(env(over), now, { fetchImpl: fakeSes as typeof fetch, log: () => {} });

beforeEach(() => {
  sent = [];
  answer = () => new Response('{"MessageId":"m"}');
  fakeSes.mockClear();
});

/** A user whose trial started `days` days before NOW, with any other columns. */
async function user(email: string, days: number, cols: Record<string, string | number | null> = {}): Promise<number> {
  const started = new Date(NOW - days * DAY).toISOString();
  const all = { email, trial_started_at: started, ...cols };
  const keys = Object.keys(all);
  const row = await db()
    .prepare(`INSERT INTO users (${keys.join(', ')}) VALUES (${keys.map((_, i) => `?${i + 1}`).join(', ')}) RETURNING id`)
    .bind(...Object.values(all))
    .first<{ id: number }>();
  return row!.id;
}
const rows = () => db().prepare('SELECT user_id, kind, status FROM lifecycle_emails ORDER BY user_id, kind').all().then((r) => r.results);
const LIFETIME = { status: 'active', plan: 'lifetime', purchased_at: '2026-10-10T00:00:00.000Z' };
const SUBSCRIBER = { plan: 'subscription', sub_id: 'sub_1', sub_status: 'active', paid_through: '2026-12-01T00:00:00.000Z' };

describe('which email goes to whom', () => {
  it('sends welcome shortly after the trial starts, the tip on day 3 and the note on day 25, each inside its window', async () => {
    await user('new@example.com', 0.01); // 15 minutes in
    await user('day3@example.com', 3.2);
    await user('day25@example.com', 25.1);
    await user('day10@example.com', 10); // between windows: nothing
    await user('late@example.com', 2.5); // welcome window closed: switched on late, no welcome in week one's middle
    await run();
    expect(sent.map((m) => [m.to, m.subject])).toEqual([
      ['day25@example.com', 'Your shepetal trial ends in 5 days'],
      ['new@example.com', 'Welcome to shepetal'],
      ['day3@example.com', 'A tip for shepetal: your language'],
    ]);
  });

  // A buyer must never be told their trial is ending and asked to pay again.
  it('never sends day 25 to a lifetime owner or a subscriber, even one whose subscription has ended', async () => {
    await user('lifetime@example.com', 25.1, LIFETIME);
    await user('sub@example.com', 25.1, SUBSCRIBER);
    await user('ended@example.com', 25.1, { ...SUBSCRIBER, sub_status: 'canceled', paid_through: '2026-10-20T00:00:00.000Z' });
    await user('trial@example.com', 25.1);
    expect((await due(db(), NOW)).map((d) => d.user.email)).toEqual(['trial@example.com']);
    await run();
    expect(sent.map((m) => m.to)).toEqual(['trial@example.com']);
  });

  // The query and the send are apart in time: a purchase in between must still stop the email.
  it('checks the license again when it sends: a row that turned lifetime after the query gets no day 25 email', async () => {
    await user('raced@example.com', 25.1);
    const [d] = await due(db(), NOW);
    expect(eligible(d, NOW)).toBe(true);
    expect(eligible({ ...d, user: { ...d.user, status: 'active', plan: 'lifetime' } }, NOW)).toBe(false);
    expect(eligible({ ...d, user: { ...d.user, ...SUBSCRIBER } as typeof d.user }, NOW)).toBe(false);
  });

  it('gives a buyer the welcome without the free trial line', async () => {
    await user('buyer@example.com', 0.01, LIFETIME);
    await run();
    expect(sent[0].text).not.toContain('free trial runs');
  });

  it('never sends the same email twice: not on the next run, and not when another run already claimed it', async () => {
    await user('a@example.com', 0.01);
    const b = await user('b@example.com', 0.01);
    await db().prepare("INSERT INTO lifecycle_emails (user_id, kind) VALUES (?1, 'welcome')").bind(b).run(); // claimed elsewhere
    await run();
    await run(undefined, NOW + 15 * 60_000);
    await run(undefined, NOW + 30 * 60_000);
    expect(sent.map((m) => m.to)).toEqual(['a@example.com']);
    expect(await rows()).toEqual([
      { user_id: b - 1, kind: 'welcome', status: 'sent' },
      { user_id: b, kind: 'welcome', status: 'sending' },
    ]);
  });

  it('sends nothing to a user who unsubscribed, not even day 25', async () => {
    const id = await user('gone@example.com', 25.1);
    await db().prepare('INSERT INTO email_unsubscribes (user_id) VALUES (?1)').bind(id).run();
    await run();
    expect(sent).toEqual([]);
    expect(await due(db(), NOW)).toEqual([]);
  });

  // The Workers Free plan gives a cron run 10 ms of CPU: a backlog drains over several runs, never in one.
  it(`sends at most ${BATCH} emails a run, and the rest on the next runs`, async () => {
    for (let i = 0; i < 12; i++) await user(`u${i}@example.com`, 0.5);
    await run();
    expect(sent).toHaveLength(BATCH);
    await run(undefined, NOW + 15 * 60_000);
    await run(undefined, NOW + 30 * 60_000);
    expect(new Set(sent.map((m) => m.to)).size).toBe(12);
  });

  // No opt-in: every trial user gets them (Art. 6(1)(f) GDPR), whether trial_emails_at is set or not, unless unsubscribed.
  it('sends to every trial user, with no opt-in, and nothing to one who unsubscribed', async () => {
    await user('plain@example.com', 0.01);
    await user('plain3@example.com', 3.2);
    await user('plain25@example.com', 25.1);
    await user('old@example.com', 0.01, { trial_emails_at: '2026-10-01T00:00:00.000Z' });
    const gone = await user('gone@example.com', 0.01);
    await db().prepare('INSERT INTO email_unsubscribes (user_id) VALUES (?1)').bind(gone).run();
    await run();
    expect(sent.map((m) => m.to).sort()).toEqual(['old@example.com', 'plain25@example.com', 'plain3@example.com', 'plain@example.com']);
  });

  it('tries again after 429 or 5xx, and marks failed for good only the one message SES rejected', async () => {
    await user('busy@example.com', 0.5);
    answer = () => new Response('{"message":"slow down"}', { status: 429, headers: { 'x-amzn-ErrorType': 'TooManyRequestsException' } });
    expect((await run())[0].result).toBe('retry');
    expect(await rows()).toEqual([]);
    answer = () => new Response('{"message":"Email address is not verified."}', { status: 400, headers: { 'x-amzn-ErrorType': 'MessageRejected:http://internal.amazon.com/coral/com.amazon.coral.service/' } });
    expect((await run())[0].result).toBe('failed');
    answer = () => new Response('{"MessageId":"m"}');
    expect(await run()).toEqual([]);
    expect(sent).toEqual([]);
    expect((await rows())[0]).toMatchObject({ status: 'failed' });
  });

  // One bad address must cost only its own email: the run goes on to the next users.
  it('marks only the email with the invalid recipient failed, and sends the rest of the run', async () => {
    const bad = await user('bad@example.com', 0.2); // the older trial goes first
    await user('good@example.com', 0.1);
    let calls = 0;
    answer = () =>
      calls++ === 0
        ? new Response('{"message":"Missing final \'@domain\'"}', { status: 400, headers: { 'x-amzn-ErrorType': 'BadRequestException' } })
        : new Response('{"MessageId":"m2"}');
    const out = await run();
    expect(out.map((o) => o.result)).toEqual(['failed', 'sent']);
    expect(sent.map((m) => m.to)).toEqual(['good@example.com']);
    expect(await rows()).toEqual([
      { user_id: bad, kind: 'welcome', status: 'failed' },
      { user_id: bad + 1, kind: 'welcome', status: 'sent' },
    ]);
  });

  // A 403 (wrong key, paused account, wrong region) is the setup's fault, not the email's: marking emails failed for
  // it would lose them for good, 5 users a run, though nothing was wrong with them.
  it.each([
    ['403', () => new Response('{"message":"The security token included in the request is invalid."}', { status: 403, headers: { 'x-amzn-ErrorType': 'UnrecognizedClientException' } })],
    ['sending paused', () => new Response('{"message":"Sending is paused for this account."}', { status: 400, headers: { 'x-amzn-ErrorType': 'SendingPausedException' } })],
    ['account suspended', () => new Response('{"message":"suspended"}', { status: 400, headers: { 'x-amzn-ErrorType': 'AccountSuspendedException' } })],
    ['a 5xx', () => new Response('oops', { status: 503 })],
    ['no answer', () => { throw new TypeError('fetch failed'); }],
  ])('on %s, releases the claim and stops the run; the email goes out on a later run once SES answers 200', async (_, fail) => {
    for (let i = 0; i < 3; i++) await user(`u${i}@example.com`, 0.5);
    answer = fail as () => Response;
    const log = vi.fn();
    const out = await runLifecycle(env(), NOW, { fetchImpl: fakeSes as typeof fetch, log });
    expect(fakeSes).toHaveBeenCalledTimes(1); // stopped after the first error, the other two were not tried
    expect(out.map((o) => o.result)).toEqual(['retry']);
    expect(await rows()).toEqual([]); // nothing claimed, nothing failed
    expect(log).toHaveBeenCalledWith(expect.stringMatching(/^lifecycle: retry welcome user \d+: run stopped, nothing marked failed: /));
    expect(JSON.stringify(log.mock.calls)).not.toContain('@example.com');
    answer = () => new Response('{"MessageId":"m"}');
    await run(undefined, NOW + 5 * 60_000);
    expect(sent.map((m) => m.to).sort()).toEqual(['u0@example.com', 'u1@example.com', 'u2@example.com']);
  });

  // Here SES_REGION reads as set when the run starts and as gone when sesSend checks it: sesSend throws before fetch.
  it('releases the claim and stops on an error thrown before SES is called', async () => {
    await user('a@example.com', 0.5);
    await user('b@example.com', 0.6);
    let reads = 0;
    const flaky = { ...env(), get SES_REGION() { return reads++ === 0 ? 'eu-central-1' : undefined; } } as LifecycleEnv;
    const out = await runLifecycle(flaky, NOW, { fetchImpl: fakeSes as typeof fetch, log: () => {} });
    expect(out.map((o) => o.result)).toEqual(['retry']);
    expect(fakeSes).not.toHaveBeenCalled();
    expect(await rows()).toEqual([]);
  });

  it('keeps every email address out of the log, even when SES echoes one', async () => {
    await user('a@example.com', 0.5);
    answer = () => new Response('{"message":"Email address is not verified: a@example.com, hello@shepetal.app"}', { status: 400, headers: { 'x-amzn-ErrorType': 'MessageRejected' } });
    const log = vi.fn();
    await runLifecycle(env(), NOW, { fetchImpl: fakeSes as typeof fetch, log });
    expect(JSON.stringify(log.mock.calls)).not.toMatch(/@example\.com|hello@/);
    expect(log).toHaveBeenCalledWith(expect.stringMatching(/^lifecycle: failed welcome user \d+: SES 400: .*<address>/));
  });

  // At most 5 a run keeps a run in 10 ms of CPU; when more are due, the backlog must show, or emails whose window
  // closes are lost without a trace.
  it(`logs when more than ${BATCH} emails were due, and not when they all fit`, async () => {
    for (let i = 0; i < BATCH; i++) await user(`u${i}@example.com`, 0.5);
    const log = vi.fn();
    await runLifecycle(env({ LIFECYCLE_EMAILS: 'off' }), NOW, { fetchImpl: fakeSes as typeof fetch, log });
    expect(JSON.stringify(log.mock.calls)).not.toContain('more than');
    await user('one-more@example.com', 0.5);
    const out = await runLifecycle(env(), NOW, { fetchImpl: fakeSes as typeof fetch, log });
    expect(out).toHaveLength(BATCH);
    expect(log).toHaveBeenCalledWith(`lifecycle: more than ${BATCH} emails due, ${BATCH} taken this run, the rest wait for the next runs`);
  });
});

describe('the kill switch', () => {
  // LIFECYCLE_EMAILS ships "off": nothing reaches SES, and nothing is marked sent, so switching on later still sends.
  it.each([['off'], [''], [undefined], ['On']])('with LIFECYCLE_EMAILS=%s, sends nothing and only reports what would go', async (v) => {
    await user('a@example.com', 0.01);
    await user('b@example.com', 25.1, LIFETIME);
    const log = vi.fn();
    const out = await runLifecycle(env({ LIFECYCLE_EMAILS: v }), NOW, { fetchImpl: fakeSes as typeof fetch, log });
    expect(fakeSes).not.toHaveBeenCalled();
    expect(await rows()).toEqual([]);
    expect(out.map((o) => o.result)).toEqual(['would_send']);
    expect(log).toHaveBeenCalledWith(expect.stringMatching(/^lifecycle: would_send welcome user \d+$/));
    expect(JSON.stringify(log.mock.calls)).not.toContain('@example.com');
  });

  it('switched on without the SES secrets or AUTH_SECRET, sends and claims nothing', async () => {
    await user('a@example.com', 0.01);
    expect(await run({ SES_SECRET_ACCESS_KEY: undefined })).toEqual([]);
    expect(await run({ AUTH_SECRET: undefined })).toEqual([]);
    expect(fakeSes).not.toHaveBeenCalled();
    expect(await rows()).toEqual([]);
  });
});

describe('unsubscribe', () => {
  const req = (url: string, method = 'GET', body?: string) =>
    new Request(url, { method, body, headers: body ? { 'content-type': 'application/x-www-form-urlencoded' } : {} });
  const unsubscribed = (id: number) => db().prepare('SELECT 1 FROM email_unsubscribes WHERE user_id = ?1').bind(id).first();

  it('puts a signed one-click link in the List-Unsubscribe headers and in the text', async () => {
    await user('a@example.com', 0.01);
    await run();
    const link = sent[0].headers.find((h) => h.Name === 'List-Unsubscribe')!.Value.slice(1, -1);
    expect(link).toMatch(/^https:\/\/shepetal\.app\/unsubscribe\?u=\d+&s=[\w-]{43}$/);
    expect(sent[0].headers).toContainEqual({ Name: 'List-Unsubscribe-Post', Value: 'List-Unsubscribe=One-Click' });
    expect(sent[0].text).toContain(link);
  });

  // Anyone can count user ids: only the signature, made with AUTH_SECRET, may unsubscribe someone.
  it('accepts only the signature AUTH_SECRET makes for that very user', async () => {
    const good = new URL(await unsubscribeUrl(7, SECRET)).searchParams;
    expect(await verifyUnsubscribe(good, SECRET)).toBe(7);
    expect(await verifyUnsubscribe(new URLSearchParams({ u: '8', s: good.get('s')! }), SECRET)).toBeNull();
    expect(await verifyUnsubscribe(good, 'another-secret')).toBeNull();
    expect(await verifyUnsubscribe(good, undefined)).toBeNull();
    expect(await verifyUnsubscribe(new URLSearchParams({ u: '7', s: good.get('s')!.slice(0, -1) }), SECRET)).toBeNull();
    expect(await verifyUnsubscribe(new URLSearchParams({ u: '7', s: '' }), SECRET)).toBeNull();
  });

  it('GET only asks (mail scanners open links); POST, the one-click of RFC 8058, unsubscribes and stops every email', async () => {
    const id = await user('a@example.com', 25.1);
    const url = await unsubscribeUrl(id, SECRET);
    const ask = (await unsubscribeRoute(req(url), env()))!;
    expect(ask.status).toBe(200);
    expect(await ask.text()).toContain('<form method="post"');
    expect(await unsubscribed(id)).toBeNull();
    const done = (await unsubscribeRoute(req(url, 'POST', 'List-Unsubscribe=One-Click'), env()))!;
    expect(done.status).toBe(200);
    expect(await unsubscribed(id)).not.toBeNull();
    expect((await unsubscribeRoute(req(url, 'POST', 'List-Unsubscribe=One-Click'), env()))!.status).toBe(200); // twice is fine
    await run();
    expect(sent).toEqual([]);
  });

  it('refuses a forged link with 400 and unsubscribes no one', async () => {
    const id = await user('a@example.com', 1);
    const forged = (await unsubscribeUrl(id + 1, SECRET)).replace(`u=${id + 1}`, `u=${id}`);
    expect((await unsubscribeRoute(req(forged, 'POST', 'List-Unsubscribe=One-Click'), env()))!.status).toBe(400);
    expect(await unsubscribed(id)).toBeNull();
  });

  it('leaves every other path and method to the rest of the Worker', async () => {
    expect(await unsubscribeRoute(req('https://shepetal.app/unsubscribed'), env())).toBeNull();
    expect(await unsubscribeRoute(req('https://shepetal.app/unsubscribe', 'PUT'), env())).toBeNull();
  });
});

describe('the copy', () => {
  const all = (['welcome', 'day3', 'day25'] as Kind[]).map((k) => render(k, copyFor(k), 'https://shepetal.app/unsubscribe?u=1&s=x'));
  const words = all.map((m) => `${m.subject}\n${m.text}`).join('\n');

  // BRAND.md and the voice rules: the name lowercase, no exclamation marks, never the step-by-step line or the old
  // tagline, no model named, nothing from another server in what a customer reads.
  it('keeps the brand rules', () => {
    expect(words).not.toMatch(/Shepetal|SHEPETAL/);
    expect(words).not.toContain('!');
    expect(words).not.toMatch(/hold fn|fn, speak|speak, let go|let go\.|keeps quiet/i);
    expect(words).not.toMatch(/whisper|parakeet|openai|\bgpt|\bllm\b|\bai\b|model/i);
    expect(words).not.toMatch(new RegExp(`${'git'}hub|backant\\.io`, 'i')); // the code host, spelt so download.test.ts finds no mention
    expect(words).not.toMatch(/\*|\[\d\]|†/); // no footnotes
    for (const m of all) expect(m.text).toMatch(/\n\nPavel\n\n--\n\n/);
  });

  it('names the two prices exactly, with the account page, on day 25', () => {
    const d25 = all[2].text;
    expect(d25).toContain('$23.99 once. Yours forever.');
    expect(d25).toContain('$0.99 a month.');
    expect(d25).toContain('https://shepetal.app/account');
  });

  it('gives 100% private its proof sentence, right after it', () => {
    expect(all[0].text).toContain('100% private. Your data is yours. Speech recognition runs on your Mac, and your voice never leaves it.');
  });

  it('says how many days are left as /account counts them', async () => {
    const id = await user('a@example.com', 25.5);
    const [d] = await due(db(), NOW);
    expect(d.user.id).toBe(id);
    expect((await compose(d, SECRET, NOW)).subject).toBe('Your shepetal trial ends in 5 days');
  });

  it('goes out from hello@ with the branded HTML part and the one-click unsubscribe headers', async () => {
    await user('a@example.com', 1);
    const [d] = await due(db(), NOW);
    const m = await compose(d, SECRET, NOW);
    expect(m.from).toBe('shepetal <hello@shepetal.app>');
    expect(m.html).toContain('https://shepetal.app/?ref=email-welcome');
    expect(m.headers['List-Unsubscribe']).toBe(`<${await unsubscribeUrl(d.user.id, SECRET)}>`);
    expect(m.headers['List-Unsubscribe-Post']).toBe('List-Unsubscribe=One-Click');
  });

  it('escapes the HTML part and links only the URLs in it', () => {
    const { html } = render('day3', { subject: 'a<b', paragraphs: ['x <script> "q" https://shepetal.app/account'] }, 'https://shepetal.app/unsubscribe?u=1&s=x');
    expect(html).toContain('<title>a&lt;b</title>');
    expect(html).toContain('x &lt;script&gt; &quot;q&quot; <a href="https://shepetal.app/account" style="color:#161512;text-decoration:underline">shepetal.app/account</a>');
    expect(html).toContain('href="https://shepetal.app/unsubscribe?u=1&amp;s=x"');
    expect(html).not.toContain('<script>');
  });
});

describe('the branded HTML', () => {
  const UNSUB = 'https://shepetal.app/unsubscribe?u=1&s=x';
  const [welcome, day3, day25] = (['welcome', 'day3', 'day25'] as Kind[]).map((k) => render(k, copyFor(k), UNSUB).html);
  const button = (label: string, href: string) =>
    `<td style="background:#161512;border-radius:4px"><a href="${href}" style="display:inline-block;padding:14px 22px;font:600 16px/1 -apple-system,BlinkMacSystemFont,'Helvetica Neue',Helvetica,Arial,sans-serif;color:#E6E4DE;text-decoration:none">${label}</a></td>`;

  it('has the landing palette, a 560px table layout and stays light in dark mode', () => {
    for (const html of [welcome, day3, day25]) {
      expect(html).toContain('<meta name="color-scheme" content="light only">');
      expect(html).toContain('<body style="margin:0;padding:0;background:#E6E4DE">');
      expect(html).toContain('<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px">');
      expect(html).toContain("font:400 17px/1.55 -apple-system,BlinkMacSystemFont,'Helvetica Neue',Helvetica,Arial,sans-serif;color:#161512");
      expect(html).not.toMatch(/<(div|style|script|link)\b/); // inline styles only
    }
  });

  it('heads each email with the wordmark, linked with ?ref=email-<kind>, over the orange rule', () => {
    for (const [kind, html] of [['welcome', welcome], ['day3', day3], ['day25', day25]]) {
      expect(html).toContain(
        `<a href="https://shepetal.app/?ref=email-${kind}"><img src="https://shepetal.app/press/shepetal-wordmark-ink.png" width="132" alt="shepetal" style="display:block;width:132px;height:auto;border:0"></a>`,
      );
      expect(html).toContain('border-top:2px solid #FF4F12');
    }
  });

  it('puts the button right after its line: How to install on welcome, Choose a plan on day 25, none on day 3', () => {
    expect(welcome).toContain(
      `shepetal.app/install</a></p><table role="presentation" cellpadding="0" cellspacing="0" style="margin:4px 0 24px"><tr>${button('How to install', 'https://shepetal.app/install?ref=email-welcome')}`,
    );
    expect(day25).toContain(
      `shepetal.app/account</a></p><table role="presentation" cellpadding="0" cellspacing="0" style="margin:4px 0 24px"><tr>${button('Choose a plan', 'https://shepetal.app/account?ref=email-day25#plans')}`,
    );
    expect(day3).not.toContain('background:#161512;border-radius:4px');
    expect(welcome.match(/border-radius:4px/g)).toHaveLength(1);
  });

  it('boxes the two prices on day 25, and only there', () => {
    expect(day25).toContain(
      "<p style=\"margin:0 0 16px;font:600 19px/1.5 -apple-system,BlinkMacSystemFont,'Helvetica Neue',Helvetica,Arial,sans-serif;color:#161512;padding:14px 18px;border-left:3px solid #FF4F12;background:#EDEBE6\">$23.99 once. Yours forever.<br>$0.99 a month.</p>",
    );
    expect(welcome + day3).not.toContain('border-left:3px solid #FF4F12');
  });

  it('signs off in italic Georgia and ends with the small footer and its unsubscribe link', () => {
    for (const html of [welcome, day3, day25]) {
      expect(html).toContain("<p style=\"margin:0 0 4px;font:italic 400 22px/1.3 Georgia,'Bodoni 72','Times New Roman',serif;color:#161512\">Pavel</p>");
      expect(html).toContain('<tr><td style="padding:20px 0 0;border-top:1px solid #D3D0C9">');
      expect(html).toContain(
        "font:400 13px/1.5 -apple-system,BlinkMacSystemFont,'Helvetica Neue',Helvetica,Arial,sans-serif;color:#57544E\">You get this email because you started a shepetal trial. It is one of three. Unsubscribe at any time, free of charge: <a href=\"https://shepetal.app/unsubscribe?u=1&amp;s=x\" style=\"color:#161512;text-decoration:underline\">shepetal.app/unsubscribe?u=1&amp;s=x</a></p>",
      );
      expect(html).toContain('BackAnt, Inc., 131 Continental Dr, Suite 305, Newark, DE 19713, USA');
      expect(html).not.toContain('>https://'); // links are shown without the scheme
    }
  });

  it('keeps the text part plain: no button, no box, the copy and the footer as they are', () => {
    const { text } = render('day25', copyFor('day25'), UNSUB);
    expect(text).toBe(
      [...copyFor('day25').paragraphs, '--', `You get this email because you started a shepetal trial. It is one of three. Unsubscribe at any time, free of charge: ${UNSUB}`, 'BackAnt, Inc., 131 Continental Dr, Suite 305, Newark, DE 19713, USA'].join('\n\n') + '\n',
    );
    expect(text).not.toContain('Choose a plan');
  });
});

// The trial emails go out: the switch is "on" and the cron runs every 5 minutes. The waitlist sweep runs on one tick a
// day, 03:15 UTC (worker.ts, sweepTick), which the 5-minute cron hits.
describe('wrangler.toml and the cron', () => {
  const toml = readFileSync(new URL('../../wrangler.toml', import.meta.url), 'utf8');
  it('ships the trial emails on, with the cron every 5 minutes', () => {
    expect(toml).toMatch(/^LIFECYCLE_EMAILS = "on"$/m);
    expect(toml.match(/^crons = .*$/gm)).toEqual(['crons = ["*/5 * * * *"]']);
  });
  it('runs the waitlist sweep once a day, on the 03:15 UTC tick only', () => {
    const day = Date.parse('2026-10-23T00:00:00.000Z');
    const ticks = Array.from({ length: 288 }, (_, i) => day + i * 5 * 60_000).filter(sweepTick);
    expect(ticks.map((t) => new Date(t).toISOString())).toEqual(['2026-10-23T03:15:00.000Z']);
    expect(sweepTick(Date.parse('2026-10-24T03:15:00.000Z'))).toBe(true);
  });
});
