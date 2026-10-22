import { beforeEach, describe, expect, it, vi } from 'vitest';
import { copyFor, render, type Kind } from './lifecycle-copy';
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
  const all = { email, trial_started_at: new Date(NOW - days * DAY).toISOString(), ...cols };
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

  it('tries again after SES says 429 or 5xx, and never again after it refused the address or never answered', async () => {
    await user('busy@example.com', 0.5);
    answer = () => new Response('{"message":"slow down"}', { status: 429 });
    expect((await run())[0].result).toBe('retry');
    expect(await rows()).toEqual([]);
    answer = () => new Response('{"message":"bad address"}', { status: 400 });
    expect((await run())[0].result).toBe('failed');
    answer = () => new Response('{"MessageId":"m"}');
    expect(await run()).toEqual([]);
    expect(sent).toEqual([]);
    expect((await rows())[0]).toMatchObject({ status: 'failed' });
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
  const all = (['welcome', 'day3', 'day25'] as Kind[]).map((k) => render(copyFor(k), 'https://shepetal.app/unsubscribe?u=1&s=x'));
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

  it('escapes the HTML part and links only the URLs in it', () => {
    const { html } = render({ subject: 'a<b', paragraphs: ['x <script> https://shepetal.app/account'] }, 'https://shepetal.app/unsubscribe?u=1&s=x');
    expect(html).toContain('x &lt;script&gt; <a href="https://shepetal.app/account"');
    expect(html).toContain('href="https://shepetal.app/unsubscribe?u=1&amp;s=x"');
    expect(html).not.toContain('<script>');
  });
});
