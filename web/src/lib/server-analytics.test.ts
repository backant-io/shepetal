import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { withEdgeHtml } from './edge-html';
import { eventOf, referrerHost, serverEvents } from './server-analytics';
import { db, useTestDb } from './test-db';
import { deviceType, isBot, osFamily } from './user-agent';

vi.mock('./db', () => import('./test-db'));
useTestDb();

// Pavel, 22.10.26: page views are counted on the server and the browser runs no analytics code, so the site needs no
// consent banner (§ 25 TDDDG, EDPB Guidelines 2/2023). That only holds if the server sends nothing that identifies a
// person (no IP, no full referrer, no account) and counts people, not bots or the router's background requests.

const CHROME = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
const IPHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1';
const IP = '203.0.113.7';
const html = (status = 200) => new Response('<html></html>', { status, headers: { 'content-type': 'text/html; charset=utf-8' } });
const at = (path: string, init: { method?: string; headers?: Record<string, string> } = {}) =>
  new Request(`https://shepetal.app${path}`, { method: init.method ?? 'GET', headers: { 'user-agent': CHROME, 'cf-connecting-ip': IP, ...init.headers } });

/** worker.ts's side of it: a ctx that collects what goes to waitUntil, and the PostHog calls the job makes. */
function run(req: Request, res: Response = html(), key = 'phc_test') {
  const later: Promise<unknown>[] = [];
  const env = { POSTHOG_KEY: key, POSTHOG_HOST: 'https://us.i.posthog.com', DB: db() };
  serverEvents(req, new URL(req.url), res, env, { waitUntil: (p) => void later.push(p) });
  return { later, done: () => Promise.all(later) };
}
const sent = (f: ReturnType<typeof vi.fn>) => f.mock.calls.map(([, init]) => JSON.parse(String((init as RequestInit).body)));

describe('server page views', () => {
  let posthog: ReturnType<typeof vi.fn<typeof fetch>>;
  beforeEach(() => {
    posthog = vi.fn<typeof fetch>(async () => new Response('{}'));
    vi.stubGlobal('fetch', posthog);
  });
  afterEach(() => vi.unstubAllGlobals());

  it('counts one $pageview for a browser GET of a page (200 or 404)', async () => {
    for (const [path, status] of [['/', 200], ['/faq', 200], ['/no-such-page', 404]] as const) {
      posthog.mockClear();
      const { done } = run(at(path), html(status));
      await done();
      expect(posthog, path).toHaveBeenCalledTimes(1);
      expect(sent(posthog)[0]).toMatchObject({ event: '$pageview', properties: { path, $pathname: path, app: 'shepetal' } });
    }
  });

  it('never counts what is not a person looking at a page: RSC, router prefetches, HEAD, assets, the API, releases, the app sign-in, bots and link previews', () => {
    const not: [string, Request, Response?][] = [
      ['RSC payload', at('/faq', { headers: { rsc: '1' } }), new Response('', { headers: { 'content-type': 'text/x-component' } })],
      ['RSC header with an HTML answer', at('/faq', { headers: { rsc: '1' } })],
      ['_rsc param', at('/faq?_rsc=abc')],
      ['next-router prefetch', at('/faq', { headers: { 'next-router-prefetch': '1' } })],
      ['browser prefetch', at('/faq', { headers: { 'sec-purpose': 'prefetch' } })],
      ['HEAD', at('/', { method: 'HEAD' })],
      ['POST', at('/', { method: 'POST' })],
      ['an asset 404', at('/wp-login.php'), html(404)],
      ['a static file', at('/og/home.jpg')],
      ['Next chunks', at('/_next/static/x')],
      ['the API', at('/api/license')],
      ['the coming-soon download page', at('/download')],
      ['a release file', at('/download/0.2.0/Shepetal-0.2.0.dmg')],
      ['the feed', at('/appcast.xml')],
      ['a redirect', at('/account'), new Response(null, { status: 307, headers: { 'content-type': 'text/html' } })],
      ['a 500', at('/'), html(500)],
      ['not HTML', at('/robots.txt'), new Response('', { headers: { 'content-type': 'text/plain' } })],
      ...['Googlebot/2.1', 'facebookexternalhit/1.1 Facebot Twitterbot/1.0', 'Slackbot-LinkExpanding 1.0', 'TelegramBot', 'WhatsApp/2.23', 'Discordbot/2.0', 'curl/8.4', 'python-requests/2.31', 'Mozilla/5.0 HeadlessChrome/120', 'node', '']
        .map((ua) => [`user agent ${JSON.stringify(ua)}`, at('/', { headers: { 'user-agent': ua } })] as [string, Request]),
    ];
    for (const [why, req, res] of not) expect(eventOf(req, new URL(req.url), res ?? html()), why).toBeNull();
  });

  it('is sent in waitUntil, after the answer: nothing goes out while the request is being answered', async () => {
    const { later, done } = run(at('/'));
    expect(later).toHaveLength(1);
    expect(posthog).not.toHaveBeenCalled();
    await done();
    expect(posthog).toHaveBeenCalledTimes(1);
  });

  it('sends no IP, no user agent, no full referrer and no query beyond ref and utm_*; the referrer host, device type and OS family only', async () => {
    const req = at('/faq?ref=producthunt&utm_source=x.com&email=ana@example.com&state=secret', {
      headers: { 'user-agent': IPHONE, referer: 'https://news.ycombinator.com/item?id=4242', 'x-forwarded-for': IP, cookie: '__Host-shepetal-session=abc' },
    });
    await run(req).done();
    const [body] = sent(posthog);
    expect(body.properties).toMatchObject({
      $current_url: 'https://shepetal.app/faq?ref=producthunt&utm_source=x.com',
      $referring_domain: 'news.ycombinator.com',
      ref: 'producthunt',
      utm_source: 'x.com',
      $device_type: 'Mobile',
      $os: 'iOS',
      $geoip_disable: true,
      $process_person_profile: false,
    });
    expect(body.distinct_id).toMatch(/^v_[0-9a-f]{32}$/);
    const all = JSON.stringify(body);
    for (const leak of [IP, '4242', 'item?id', 'ana@example.com', 'secret', 'iPhone OS 18', 'Safari', 'session-token', 'abc']) expect(all, leak).not.toContain(leak);
    expect(body.properties).not.toHaveProperty('$ip');
    expect(body.properties).not.toHaveProperty('$referrer');
  });

  it('does nothing at all without POSTHOG_KEY', () => {
    expect(run(at('/'), html(), '').later).toEqual([]);
  });

  it('the referrer is a host or $direct, never more', () => {
    expect(referrerHost('https://www.google.com/search?q=dictation+mac')).toBe('www.google.com');
    expect(referrerHost(null)).toBe('$direct');
    expect(referrerHost('not a url')).toBe('$direct');
  });

  it('the user agent gives a device type and an OS family, and bots are a short list', () => {
    expect([deviceType(CHROME), osFamily(CHROME)]).toEqual(['Desktop', 'Mac OS X']);
    expect([deviceType(IPHONE), osFamily(IPHONE)]).toEqual(['Mobile', 'iOS']);
    expect(deviceType('Mozilla/5.0 (Linux; Android 14; SM-X910) AppleWebKit/537.36 Chrome/131 Safari/537.36')).toBe('Tablet');
    expect(osFamily('Mozilla/5.0 (Windows NT 10.0; Win64; x64)')).toBe('Windows');
    expect(isBot(CHROME) || isBot(IPHONE)).toBe(false);
  });
});

describe('the app sign-in funnel: app_login_opened and app_login_consented', () => {
  let posthog: ReturnType<typeof vi.fn<typeof fetch>>;
  beforeEach(() => {
    posthog = vi.fn<typeof fetch>(async () => new Response('{}'));
    vi.stubGlobal('fetch', posthog);
  });
  afterEach(() => vi.unstubAllGlobals());
  const EMAIL = 'ana@example.com';
  const q = (redirect: string, extra = '') =>
    `/app/login?redirect_uri=${encodeURIComponent(redirect)}&state=s3cr3t-state&code_challenge=${'a'.repeat(43)}&code_challenge_method=S256${extra}`;
  const consentPage = () => html(200);

  it('app_login_opened carries only the anonymous v_ id: never the account, its email, the session or the state', async () => {
    const req = at(q('shepetal://auth', '&app_version=0.3.0'), { headers: { cookie: `__Host-shepetal-session=sealed-for-${EMAIL}`, 'sec-fetch-site': 'none' } });
    await run(req, consentPage()).done();
    const [body] = sent(posthog);
    expect(body).toMatchObject({ event: 'app_login_opened', properties: { client: 'app', app_version: '0.3.0', signed_in: true, $process_person_profile: false } });
    expect(body.distinct_id).toMatch(/^v_[0-9a-f]{32}$/);
    expect(body.properties).not.toHaveProperty('$set');
    const all = JSON.stringify(body);
    for (const leak of [EMAIL, 'jwt-of', 's3cr3t', 'aaaaaaaa', IP]) expect(all, leak).not.toContain(leak);
  });

  it('counts the open once: not the return from Google, not "Not you?", not a bad request, not a website redirect_uri', () => {
    const ev = (req: Request, res: Response = consentPage()) => eventOf(req, new URL(req.url), res);
    expect(ev(at(q('http://127.0.0.1:53682/callback')), new Response(null, { status: 302, headers: { location: 'https://accounts.google.com/x' } }))).toBe('app_login_opened');
    expect(ev(at(q('shepetal://auth'), { headers: { 'sec-fetch-site': 'cross-site' } }))).toBeNull();
    expect(ev(at(q('shepetal://auth', '&switch=1')))).toBeNull();
    expect(ev(at(q('shepetal://auth')), new Response('Bad sign-in request', { status: 400 }))).toBeNull();
    expect(ev(at(q('https://evil.example/callback')), new Response('Bad', { status: 400 }))).toBeNull();
    expect(ev(at(q('shepetal://auth'), { method: 'HEAD' }))).toBeNull();
    expect(ev(at(q('shepetal://auth'), { headers: { 'user-agent': 'Slackbot 1.0' } }))).toBeNull();
    // Not a page view either: the app's sign-in is not a visit to the site.
    expect(ev(at('/app/login'))).toBeNull();
  });

  it('app_login_consented: the consent POST that sends the code to the app; the code is never sent', async () => {
    const ok = new Response(null, { status: 302, headers: { location: 'shepetal://auth?code=the-one-time-code&state=s3cr3t-state' } });
    await run(at('/app/login', { method: 'POST', headers: { 'user-agent': 'shepetal/0.3.0 (Macintosh)' } }), ok).done();
    const [body] = sent(posthog);
    expect(body).toMatchObject({ event: 'app_login_consented', properties: { client: 'app', app_version: '0.3.0' } });
    expect(JSON.stringify(body)).not.toMatch(/the-one-time-code|s3cr3t/);
    // A refused consent (403, 401, 400) is not a consent.
    for (const status of [400, 401, 403]) expect(eventOf(at('/app/login', { method: 'POST' }), new URL('https://shepetal.app/app/login'), new Response('', { status }))).toBeNull();
  });
});

describe('the browser runs no analytics code', () => {
  const WEB = join(__dirname, '..', '..');
  it('posthog-js is not a dependency, and no source file loads it or the analytics meta', () => {
    expect(readFileSync(join(WEB, 'package.json'), 'utf8')).not.toContain('posthog-js');
    expect(readFileSync(join(WEB, 'package-lock.json'), 'utf8')).not.toContain('posthog-js');
    const SRC = join(WEB, 'src');
    const files = readdirSync(SRC, { recursive: true, encoding: 'utf8' }).filter((f) => /\.(tsx?|css)$/.test(f) && !f.endsWith('.test.ts'));
    expect(files.filter((f) => /posthog-js|shepetal-analytics/.test(readFileSync(join(SRC, f), 'utf8')))).toEqual([]);
  });

  it('pages get no analytics meta at the edge, with the key set or not', () => {
    const page = new Response('<html><head></head></html>', { headers: { 'content-type': 'text/html' } });
    expect(withEdgeHtml(page, new URL('https://shepetal.app/faq'))).toBe(page);
  });

  it('the build has no PostHog in any browser chunk (checked when a build is there)', () => {
    const dir = join(WEB, '.open-next', 'assets', '_next', 'static');
    let chunks: string[];
    try {
      chunks = readdirSync(dir, { recursive: true, encoding: 'utf8' }).filter((f) => f.endsWith('.js'));
    } catch {
      return; // no build in this checkout; e2e/run.mjs checks the served pages
    }
    expect(chunks.filter((f) => /posthog/i.test(readFileSync(join(dir, f), 'utf8')))).toEqual([]);
  });
});
