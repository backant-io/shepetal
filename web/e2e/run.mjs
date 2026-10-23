#!/usr/bin/env node
// End-to-end login test for the account service (API.md), on the real Worker runtime.
//
// It builds the Worker (opennextjs-cloudflare build), applies migrations/ to a fresh local D1,
// starts `wrangler dev` on 127.0.0.1 and a fake Stripe API, then signs in the way the apps do
// (OAuth for native apps with PKCE): GET /app/login signed out goes to Google and comes back,
// signed in it redirects to shepetal://auth with a one-time code, POST /api/app/token trades it
// for a token, license = trial, checkout per plan = a Stripe Checkout URL, signed webhooks for the
// subscription (paid, failed, cancelled), the Billing Portal, then the lifetime license. Then the redirect_uri and PKCE rules.
// Before that, /download and /appcast.xml against the local R2 bucket, before and after a release is put there the way
// promote.sh does. Last, the trial emails: the Cron Trigger against a fake SES, and the unsubscribe link they carry.
//
// Google is faked with a next-auth session cookie signed with the run's AUTH_SECRET, so the run
// needs no Google account and no network except Google's OIDC discovery (for the sign-in redirect).
// No real secret is read: every value is generated per run.
//
//   npm run e2e                   # from web/
//   E2E_SKIP_BUILD=1 npm run e2e  # reuse .open-next/ from the last build
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { createHash, createHmac, randomBytes } from 'node:crypto';
import { createWriteStream, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { encode } from 'next-auth/jwt';

const WEB = join(dirname(fileURLToPath(import.meta.url)), '..');
const BIN = join(WEB, 'node_modules', '.bin');
const DB_ID = 'bd45470f-27b2-4564-aa94-850856413b3e'; // wrangler.toml
const MAC = 'shepetal://auth'; // the Mac and iPhone redirect_uri
const DAY = 86_400_000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const tmp = mkdtempSync(join(tmpdir(), 'shepetal-e2e-'));
const t0 = Date.now();
let step = 0;
const failed = [];
const ok = (msg) => console.log(`ok ${++step} - ${msg}`);
/** A check the rest of the run does not depend on: report it and go on. */
async function check(name, fn) {
  try {
    await fn();
    ok(name);
  } catch (e) {
    failed.push(name);
    console.log(`not ok ${++step} - ${name}\n    ${e.message.split('\n').join('\n    ')}`);
  }
}
// Stripe form params `metadata[app]=x` -> {app: 'x'}.
const metadataOf = (params) =>
  Object.fromEntries(Object.entries(params).flatMap(([k, v]) => (k.startsWith('metadata[') ? [[k.slice(9, -1), v]] : [])));
const b64url = (buf) => buf.toString('base64url');

const freePort = () =>
  new Promise((resolve) => {
    const s = createServer().listen(0, '127.0.0.1', () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });

// ---- Fake Stripe API: the calls checkout, the webhook and the Billing Portal make. Anything else is a test failure.
const stripeCalls = [];
const DAY_S = 86_400;
const fakeSub = {
  id: 'sub_e2e',
  object: 'subscription',
  customer: 'cus_e2e',
  status: 'active',
  current_period_start: Math.floor(Date.now() / 1000),
  current_period_end: Math.floor(Date.now() / 1000) + 30 * DAY_S,
  cancel_at_period_end: false,
  ended_at: null,
  metadata: {},
  items: { object: 'list', data: [] },
};
const phEvents = [];
// The same server stands in for Amazon SES v2 (SES_API_BASE): every customer email (the cancellation and purchase
// confirmations, the trial emails the cron sends).
const sesCalls = [];
const fakeStripe = createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    const url = new URL(req.url, 'http://x');
    const params = { ...Object.fromEntries(url.searchParams), ...Object.fromEntries(new URLSearchParams(req.method === 'GET' ? '' : body)) };
    // The same server stands in for PostHog's capture API (POSTHOG_HOST); those calls are not Stripe's.
    if (req.method === 'POST' && url.pathname === '/i/v0/e/') {
      phEvents.push(JSON.parse(body));
      return res.end('{"status":"Ok"}');
    }
    if (req.method === 'POST' && url.pathname === '/v2/email/outbound-emails') {
      sesCalls.push({ auth: req.headers.authorization, amzDate: req.headers['x-amz-date'], body: JSON.parse(body) });
      res.setHeader('content-type', 'application/json');
      return res.end(JSON.stringify({ MessageId: `ses-e2e-${sesCalls.length}` }));
    }
    stripeCalls.push({ method: req.method, path: url.pathname, params, auth: req.headers.authorization });
    res.setHeader('content-type', 'application/json');
    const route = `${req.method} ${url.pathname}`;
    const reply = (o) => res.end(JSON.stringify(o));
    if (route === 'GET /v1/prices') {
      const key = params['lookup_keys[0]'];
      return reply({ object: 'list', has_more: false, data: [{ id: `price_e2e_${key}`, object: 'price', lookup_key: key, active: true }] });
    }
    if (route === 'POST /v1/customers') return reply({ id: 'cus_e2e', object: 'customer', email: params.email, metadata: metadataOf(params) });
    if (route === 'POST /v1/checkout/sessions') {
      const id = `cs_test_e2e_${stripeCalls.length}`;
      return reply({
        id,
        object: 'checkout.session',
        mode: params.mode,
        status: 'open',
        payment_status: 'unpaid',
        client_reference_id: params.client_reference_id ?? null,
        customer: params.customer ?? null,
        metadata: metadataOf(params),
        url: `https://checkout.stripe.com/c/pay/${id}`,
      });
    }
    if (route === 'GET /v1/subscriptions/sub_e2e') return reply(fakeSub);
    if (route === 'GET /v1/checkout/sessions') return reply({ object: 'list', has_more: false, data: [] });
    if (route === 'GET /v1/promotion_codes') {
      const coupon = params.code === 'PRODUCTHUNT' ? { id: 'shepetal_producthunt', metadata: { app: 'shepetal' } } : { id: 'backant100', metadata: {} };
      return reply({ object: 'list', has_more: false, data: [{ id: `promo_e2e_${params.code}`, object: 'promotion_code', code: params.code, active: true, coupon }] });
    }
    if (route === 'GET /v1/invoices/in_e2e') return reply({ id: 'in_e2e', object: 'invoice', status: fakeSub.status === 'past_due' ? 'open' : 'paid' });
    if (route === 'POST /v1/subscriptions/sub_e2e') {
      // As Stripe does: cancel at period end sets cancel_at to the period end; cancel_at '' clears it.
      if (params.cancel_at_period_end) {
        fakeSub.cancel_at_period_end = params.cancel_at_period_end === 'true';
        fakeSub.cancel_at = fakeSub.cancel_at_period_end ? fakeSub.current_period_end : null;
      }
      if ('cancel_at' in params) Object.assign(fakeSub, { cancel_at: params.cancel_at ? Number(params.cancel_at) : null, cancel_at_period_end: false });
      return reply(fakeSub);
    }
    if (route === 'DELETE /v1/subscriptions/sub_e2e') {
      Object.assign(fakeSub, { status: 'canceled', ended_at: Math.floor(Date.now() / 1000) });
      return reply(fakeSub);
    }
    if (route === 'GET /v1/invoices') return reply({ object: 'list', has_more: false, data: [] });
    if (route === 'GET /v1/billing_portal/configurations') {
      return reply({ object: 'list', has_more: false, data: [{ id: 'bpc_other', object: 'billing_portal.configuration', metadata: {} }, { id: 'bpc_e2e', object: 'billing_portal.configuration', metadata: { app: 'shepetal' } }] });
    }
    if (route === 'POST /v1/billing_portal/sessions') return reply({ id: 'bps_e2e', object: 'billing_portal.session', url: 'https://billing.stripe.com/p/session/test_e2e' });
    res.statusCode = 404;
    reply({ error: { type: 'invalid_request_error', message: `fake Stripe: no ${req.method} ${req.url}` } });
  });
});

// ---- Per-run configuration (never real secrets).
const port = await freePort();
// localhost, not 127.0.0.1: Next's NextURL rewrites 127.0.0.1 to localhost, so next-auth sees localhost.
const BASE = `http://localhost:${port}`;
await new Promise((r) => fakeStripe.listen(0, '127.0.0.1', r));
const env = {
  AUTH_SECRET: randomBytes(32).toString('hex'),
  AUTH_URL: BASE,
  NEXTAUTH_URL: BASE,
  GOOGLE_CLIENT_ID: 'e2e-client-id',
  GOOGLE_CLIENT_SECRET: 'e2e-client-secret',
  STRIPE_SECRET_KEY: 'sk_test_e2e',
  STRIPE_WEBHOOK_SECRET: `whsec_${randomBytes(24).toString('hex')}`,
  STRIPE_API_BASE: `http://127.0.0.1:${fakeStripe.address().port}`,
  POSTHOG_KEY: 'phc_e2e',
  POSTHOG_HOST: `http://127.0.0.1:${fakeStripe.address().port}`,
  SES_ACCESS_KEY_ID: 'AKIDE2E',
  SES_SECRET_ACCESS_KEY: randomBytes(20).toString('hex'),
  SES_REGION: 'eu-central-1',
  SES_API_BASE: `http://127.0.0.1:${fakeStripe.address().port}`,
  LIFECYCLE_EMAILS: 'on',
};
// An env file instead of --var keeps values out of `ps`, and replaces any developer .dev.vars.
const envFile = join(tmp, 'e2e.env');
writeFileSync(envFile, Object.entries(env).map(([k, v]) => `${k}=${v}`).join('\n') + '\n', { mode: 0o600 });

let worker;
const logFile = join(tmp, 'wrangler.log');

// ---- What an app does (RFC 8252 + RFC 7636): a verifier, its S256 challenge, a random state.
function pkce(redirect_uri = MAC, state = `${b64url(randomBytes(12))} &=+/é%`) {
  const verifier = b64url(randomBytes(32));
  const challenge = b64url(createHash('sha256').update(verifier).digest());
  const q = new URLSearchParams({ redirect_uri, state, code_challenge: challenge, code_challenge_method: 'S256' });
  return { verifier, state, redirect_uri, url: `${BASE}/app/login?${q}` };
}
/** The browser (ASWebAuthenticationSession) on /app/login: it stops at the first redirect. */
const browse = (url, cookie) => fetch(url, { redirect: 'manual', headers: cookie ? { cookie } : {} });
const unescape = (s) => s.replace(/&#(\d+);/g, (_, n) => String.fromCharCode(n)).replace(/&quot;/g, '"').replace(/&amp;/g, '&');
/** The consent page's form fields. */
const formOf = (html) =>
  Object.fromEntries([...html.matchAll(/<input type="hidden" name="([^"]+)" value="([^"]*)">/g)].map(([, k, v]) => [k, unescape(v)]));
/** GET the consent page as the signed-in user, then press Continue: the POST a browser sends. */
async function consent(url, session, { origin = BASE, fields = {}, cookies = true } = {}) {
  const page = await browse(url, session);
  assert.equal(page.status, 200, `consent page: ${page.status} ${page.headers.get('location')}`);
  const jar = [session, ...(cookies ? page.headers.getSetCookie().map((c) => c.split(';')[0]) : [])].filter(Boolean).join('; ');
  const headers = { cookie: jar, 'content-type': 'application/x-www-form-urlencoded', ...(origin && { origin }) };
  const body = new URLSearchParams(Object.entries({ ...formOf(await page.text()), ...fields }).filter(([, v]) => v !== null));
  return fetch(`${BASE}/app/login`, { method: 'POST', redirect: 'manual', headers, body });
}
/** The redirect to the app: its code and state. */
function landing(res, redirect_uri) {
  const to = res.headers.get('location') ?? '';
  assert.equal(res.status, 302, `/app/login signed in: ${res.status} ${to}`);
  assert.ok(to.startsWith(`${redirect_uri}?`), `redirects to ${redirect_uri}, got ${to}`);
  const q = new URL(to).searchParams;
  return { code: q.get('code'), state: q.get('state') };
}
/** POST /api/app/token as the app sends it. */
async function token(body) {
  const r = await fetch(`${BASE}/api/app/token`, {
    method: 'POST',
    headers: { accept: 'application/json', 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  return { status: r.status, body: await r.json().catch(() => null) };
}

// ---- The app's account requests (AccountClient.send): JSON in and out, Bearer token when signed in.
async function app(method, path, { token, json } = {}) {
  const headers = { accept: 'application/json' };
  if (token) headers.authorization = `Bearer ${token}`;
  if (json) headers['content-type'] = 'application/json';
  const r = await fetch(BASE + path, { method, headers, body: json && JSON.stringify(json) });
  const text = await r.text();
  try {
    return { status: r.status, body: JSON.parse(text) };
  } catch {
    return { status: r.status, body: text };
  }
}
const sessionFor = async (email) => {
  const name = 'authjs.session-token'; // http: no __Secure- prefix
  return `${name}=${await encode({ token: { email, name: 'E2E', sub: email }, secret: env.AUTH_SECRET, salt: name })}`;
};

/** SQL on the local D1 of the running worker (wrangler's local explorer). */
async function d1(sql) {
  const r = await fetch(`${BASE}/cdn-cgi/local/explorer/api/d1/database/${DB_ID}/raw`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ sql }),
  });
  const j = await r.json();
  assert.ok(j.success && j.result.every((x) => x.success), `d1: ${JSON.stringify(j.errors ?? j)}`);
  return j.result.at(-1).results.rows;
}

async function main() {
  const wrangler = (args) => execFileSync(join(BIN, 'wrangler'), args, { cwd: WEB, stdio: ['ignore', 'pipe', 'pipe'] });
  if (!process.env.E2E_SKIP_BUILD) {
    execFileSync(join(BIN, 'opennextjs-cloudflare'), ['build'], { cwd: WEB, stdio: ['ignore', 'pipe', 'inherit'] });
    ok('opennextjs-cloudflare build');
  }
  // The prerendered pages' copies (open-next.config.ts) go into the assets on `opennextjs-cloudflare deploy|upload`,
  // not on a build: without them every page is rendered again, which the fast-path check below catches.
  execFileSync(join(BIN, 'opennextjs-cloudflare'), ['populateCache', 'local'], { cwd: WEB, stdio: ['ignore', 'pipe', 'inherit'] });
  ok('populateCache local: the prerendered pages are in the assets');
  const state = join(tmp, 'state');
  wrangler(['d1', 'migrations', 'apply', 'DB', '--local', '--persist-to', state]);
  ok('migrations applied to a fresh local D1');

  const log = createWriteStream(logFile);
  // --local-upstream: with the custom-domain route in wrangler.toml, wrangler dev otherwise rewrites Host and
  // Origin to the first custom domain, and the consent POST fails its Origin check against AUTH_URL with a 403.
  worker = spawn(
    join(BIN, 'wrangler'),
    ['dev', '--ip', '127.0.0.1', '--port', String(port), '--inspector-port', String(await freePort()),
      '--local-upstream', `localhost:${port}`,
      '--persist-to', state, '--env-file', envFile, '--show-interactive-dev-session=false', '--test-scheduled'],
    { cwd: WEB, detached: true, stdio: ['ignore', 'pipe', 'pipe'] },
  );
  worker.stdout.pipe(log);
  worker.stderr.pipe(log);
  for (let i = 0; ; i++) {
    if (worker.exitCode !== null) throw new Error(`wrangler dev exited with ${worker.exitCode}`);
    if ((await fetch(`${BASE}/api/auth/providers`).catch(() => null))?.ok) break;
    if (i > 120) throw new Error('wrangler dev did not answer within 60 s');
    await sleep(500);
  }
  ok(`wrangler dev answers on ${BASE}`);

  // ---- 0. The landing page renders on the Worker, starts the trial with a link to /install (no sign-in) and
  // loads every script, style, font and image from the site itself (no trackers, no font CDN).
  await check('landing page: the trial button links to /install (no sign-in form), nothing loaded from another server, fonts only from self', async () => {
    const res = await fetch(`${BASE}/`);
    const html = await res.text();
    assert.equal(res.status, 200);
    assert.ok(html.includes('>Try 30 days free</a>') && !/<form\b/.test(html), 'the trial button is a link, not a sign-in form');
    // Assets (src, srcset, stylesheets, preloads) and visible links; the canonical <link> names the site's own domain.
    const outside = [
      ...html.matchAll(/\b(?:src|srcset)="(https?:\/\/[^"]+)"/g),
      ...html.matchAll(/<(?:a|link(?![^>]*rel="(?:canonical|alternate)"))\b[^>]*\bhref="(https?:\/\/[^"]+)"/g),
    ].map((m) => m[1]);
    assert.deepEqual(outside, [], 'no asset or link to another server');
    assert.match(res.headers.get('content-security-policy') ?? '', /font-src 'self' data:/);
    // The X card: a large image at an absolute URL, served as a static file.
    assert.match(html, /<meta property="og:image" content="https:\/\/shepetal\.app\/og\/home\.jpg"/);
    assert.match(html, /<meta name="twitter:card" content="summary_large_image"/);
    const og = await fetch(`${BASE}/og/home.jpg`);
    assert.equal(og.status, 200);
    assert.match(og.headers.get('content-type') ?? '', /^image\/jpeg/);
    await og.arrayBuffer(); // an unread body leaves the socket behind, and the next request on it fails with EPIPE
    // The footer's Legal link carries the attribution and trademark notices the page no longer prints.
    assert.ok(html.includes('href="/legal"'), 'the footer links to /legal');
    const legal = await fetch(`${BASE}/legal`);
    assert.equal(legal.status, 200);
    assert.ok((await legal.text()).includes('/brand/emoji/NOTICE.txt'), '/legal links the Noto NOTICE');
  });

  // ---- 0a. The Workers Free plan gives a request 10 ms of CPU, and a React render or loading the Next server takes more.
  // So the prerendered pages, their RSC payloads, the not-found page, robots and the sitemap are served from the build's
  // copies (x-opennext-cache: HIT: the Next server never ran), and /api/license by worker.ts itself, each with the
  // security headers; worker.ts adds what depends on the request (/install's attribution) and nothing else: no
  // analytics meta, no analytics script (page views are counted on the server).
  await check('fast paths: pages, RSC and segment prefetches, the 404 page, robots and the sitemap from the prerendered cache with the security headers; /install carries ?ref= on; /api/license 401 from worker.ts with them too', async () => {
    const secure = (r, what) => {
      assert.equal(r.headers.get('strict-transport-security'), 'max-age=31536000; includeSubDomains; preload', what);
      assert.match(r.headers.get('content-security-policy') ?? '', /form-action 'self' https:\/\/accounts\.google\.com https:\/\/checkout\.stripe\.com shepetal: http:\/\/127\.0\.0\.1:\*/, what);
      assert.match(r.headers.get('content-security-policy') ?? '', /font-src 'self' data:/, what);
      assert.deepEqual(['x-frame-options', 'x-content-type-options', 'referrer-policy', 'permissions-policy'].map((h) => r.headers.get(h)),
        ['DENY', 'nosniff', 'strict-origin-when-cross-origin', 'camera=(), microphone=(), geolocation=()'], what);
    };
    const cached = async (path, headers = {}, status = 200) => {
      const r = await fetch(`${BASE}${path}`, { headers });
      const what = `${path} ${JSON.stringify(headers)}`;
      assert.equal(r.status, status, what);
      assert.equal(r.headers.get('x-opennext-cache'), 'HIT', `${what} is served from the prerendered cache`);
      secure(r, what);
      return { type: r.headers.get('content-type'), body: await r.text() };
    };
    const tracker = /shepetal-analytics|posthog/i;
    for (const path of ['/', '/faq']) assert.doesNotMatch((await cached(path)).body, tracker, path);
    // A page OpenNext served from its copy is kept in the data center's cache (worker.ts), one entry per body.
    const again = await fetch(`${BASE}/`);
    assert.equal(again.headers.get('cf-cache-status'), 'HIT', 'the second / comes from the cache');
    secure(again, '/ from the cache');
    assert.doesNotMatch(await again.text(), tracker, 'the cached page has no analytics meta either');
    assert.equal((await cached('/', { rsc: '1' })).type, 'text/x-component', 'the RSC payload of a cached page is its own entry');
    assert.equal((await cached('/faq', { rsc: '1' })).type, 'text/x-component');
    assert.equal((await cached('/faq', { rsc: '1', 'next-router-prefetch': '1', 'next-router-segment-prefetch': '/_tree' })).type, 'text/x-component');
    const missing = await cached('/perf-probe-not-found', {}, 404);
    assert.match(missing.type ?? '', /^text\/html/);
    assert.doesNotMatch(missing.body, tracker, 'the 404 page has no analytics meta');
    for (const path of ['/robots.txt', '/sitemap.xml']) await cached(path);
    const install = (await cached('/install?ref=x&utm_source=y')).body;
    assert.equal(unescape(install.match(/http-equiv="refresh" content="1;url=([^"]+)"/i)?.[1] ?? ''), '/download?ref=x&utm_source=y', 'the refresh carries the attribution');
    assert.equal(install.match(/http-equiv="refresh"/gi)?.length, 1, 'one refresh only: a second, bare one (from React) is what browsers followed');
    assert.equal(unescape(install.match(/<a href="(\/download[^"]*)"/)?.[1] ?? ''), '/download?ref=x&utm_source=y', 'the fallback link too');
    assert.match(install, /<meta name="robots" content="noindex"/, '/install stays out of search');
    const license = await fetch(`${BASE}/api/license`);
    assert.deepEqual([license.status, await license.json()], [401, { error: 'invalid_token' }]);
    secure(license, '/api/license');
  });

  // ---- 0b. Download is open (sign-in happens in the app) and the Sparkle feed is on this site, both from the local R2
  // bucket: coming soon and an empty feed before the first promotion, then what latest.json names. staging/ is never served.
  await check('/download and /appcast.xml signed out: coming soon, then the promoted DMG (resumable) and its feed as stored; never sign-in', async () => {
    const before = await fetch(`${BASE}/download`, { redirect: 'manual' });
    assert.equal(before.status, 200, `/download before a release: ${before.status} ${before.headers.get('location')}`);
    assert.ok((await before.text()).includes('coming soon'), 'coming soon page');
    const empty = await fetch(`${BASE}/appcast.xml`);
    const xml = await empty.text();
    assert.equal(empty.headers.get('content-type'), 'application/xml; charset=utf-8');
    assert.ok(xml.includes('<rss') && !xml.includes('<item>'), `empty feed: ${xml}`);

    // What scripts/mac/promote.sh leaves in R2, and a staged build that was never promoted.
    const v = '0.0.1';
    const dmg = randomBytes(300_000);
    const feed = `<?xml version="1.0"?>\n<rss version="2.0"><channel><item><enclosure url="${BASE}/download/${v}/Shepetal-${v}.dmg" length="${dmg.length}"/></item></channel></rss>\n`;
    const put = (key, data) => {
      writeFileSync(join(tmp, 'object'), data);
      wrangler(['r2', 'object', 'put', `shepetal-releases/${key}`, '--local', '--persist-to', state, '--file', join(tmp, 'object')]);
    };
    put(`releases/${v}/Shepetal-${v}.dmg`, dmg);
    put(`releases/${v}/appcast.xml`, feed);
    put('staging/0.0.2/Shepetal-0.0.2.dmg', 'unreviewed');
    put('latest.json', JSON.stringify({ version: v, build: 1 }));

    const dl = await fetch(`${BASE}/download`, { redirect: 'manual' });
    assert.equal(dl.status, 302);
    assert.equal(dl.headers.get('location'), `/download/${v}/Shepetal-${v}.dmg`, 'a relative redirect to the DMG on this site');
    const url = new URL(dl.headers.get('location'), BASE);
    const whole = await fetch(url);
    assert.equal(whole.status, 200);
    assert.ok(Buffer.from(await whole.arrayBuffer()).equals(dmg), 'the DMG as stored');
    assert.equal(whole.headers.get('cache-control'), 'public, max-age=31536000, immutable');
    const rest = await fetch(url, { headers: { range: 'bytes=100000-' } }); // a resumed download
    assert.equal(rest.status, 206);
    assert.equal(rest.headers.get('content-range'), `bytes 100000-${dmg.length - 1}/${dmg.length}`);
    assert.ok(Buffer.from(await rest.arrayBuffer()).equals(dmg.subarray(100000)), 'the rest of the DMG');
    const now = await fetch(`${BASE}/appcast.xml`);
    assert.equal(now.headers.get('content-type'), 'application/xml; charset=utf-8');
    assert.equal(await now.text(), feed, 'the promoted feed as stored');
    for (const p of ['/download/0.0.2/Shepetal-0.0.2.dmg', `/download/${v}/latest.json`, '/latest.json']) {
      assert.equal((await fetch(`${BASE}${p}`)).status, 404, p);
    }
  });

  // ---- 0c. Download is open: the landing page's main CTA, followed signed out, reaches the DMG with no sign-in on the way.
  await check('landing CTA signed out: Try 30 days free -> /install -> /download -> the DMG, no auth redirect', async () => {
    const html = await (await fetch(`${BASE}/`)).text();
    const cta = html.match(/<a class="kc-cta[^"]*" href="([^"]+)">(?:<svg[^>]*>.*?<\/svg>)?Try 30 days free<\/a>/)?.[1];
    assert.equal(cta, '/install', 'the main CTA');
    const install = await fetch(`${BASE}${cta}?ref=e2e`, { redirect: 'manual' });
    assert.equal(install.status, 200, `/install: ${install.status} ${install.headers.get('location')}`);
    const next = unescape((await install.text()).match(/http-equiv="refresh" content="1;url=([^"]+)"/i)?.[1] ?? '');
    assert.equal(next, '/download?ref=e2e', 'the install guide starts the download, with the attribution');
    const dl = await fetch(`${BASE}${next}`, { redirect: 'manual' });
    assert.equal(dl.status, 302, `/download: ${dl.status}`);
    assert.match(dl.headers.get('location') ?? '', /^\/download\/[\d.]+\/Shepetal-[\d.]+\.dmg$/, 'straight to the DMG, not to sign-in');
  });

  // ---- 1. Signed out, /app/login runs the Google sign-in and comes back to the same URL.
  const login = pkce();
  const out = await browse(login.url);
  const google = new URL(out.headers.get('location') ?? 'about:blank');
  assert.equal(google.origin, 'https://accounts.google.com', `signed out goes to Google, got ${out.status} ${google}`);
  assert.equal(google.searchParams.get('redirect_uri'), `${BASE}/api/auth/callback/google`);
  const back = out.headers.getSetCookie().find((c) => c.startsWith('authjs.callback-url='));
  assert.equal(decodeURIComponent(back?.split(';')[0].split('=')[1] ?? ''), login.url, 'after Google, next-auth returns to /app/login with the same query');
  ok(`/app/login signed out: ${out.status} to Google with redirect_uri <AUTH_URL>/api/auth/callback/google, back to the same /app/login after`);

  // ---- 1b. The sign-in page: one action, Continue with Google, as a real form.
  await check('sign-in: /login and /account signed out show Continue with Google as a sign-in form', async () => {
    for (const path of ['/login', '/account']) {
      const r = await browse(`${BASE}${path}`);
      const html = await r.text();
      assert.equal(r.status, 200, `${path}: ${r.status}`);
      assert.ok(html.includes('Sign in.') && html.includes('Continue with Google') && /<form[^>]*action=/.test(html), `${path} is the sign-in page`);
    }
  });

  // ---- 2. Fake the Google sign-in: a next-auth JWT session cookie, as the callback would set it.
  const email = `e2e-${randomBytes(4).toString('hex')}@example.com`;
  const session = await sessionFor(email);
  const me = await (await fetch(`${BASE}/api/auth/session`, { headers: { cookie: session } })).json();
  assert.equal(me?.user?.email, email, 'the test session is accepted');
  ok(`test session for ${email}`);
  /** The account page as the signed-in user sees it, as text with the tags stripped. */
  const accountText = async () => {
    const r = await browse(`${BASE}/account`, session);
    assert.equal(r.status, 200, `/account: ${r.status}`);
    return (await r.text()).replace(/<!--.*?-->/g, '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ');
  };
  await check('/account, trial: days left, the download, the email and the two plans; no subscription controls', async () => {
    const t = await accountText();
    for (const s of ['30 days left.', 'Download for Mac', 'Settings', email, 'Free trial', '$23.99', 'once. Yours forever.', '$0.99', 'a month.', 'Buy once', 'Subscribe'])
      assert.ok(t.includes(s), `trial account shows ${s}`);
    for (const s of ['Cancel subscription', 'Switch to lifetime', 'Manage billing']) assert.ok(!t.includes(s), `no ${s} on a trial`);
    const r = await browse(`${BASE}/login`, session);
    assert.deepEqual([r.status, new URL(r.headers.get('location') ?? '', BASE).pathname], [307, '/account'], '/login signed in goes to the account');
  });

  // ---- 3. Signed in, a GET shows the consent page and issues nothing; Continue (a POST) redirects
  // to the app with a one-time code and the state unchanged.
  const codes = async () => (await d1('SELECT count(*) FROM app_codes'))[0][0];
  const page = await browse(login.url, session);
  const html = await page.text();
  assert.equal(page.status, 200, `consent page: ${page.status} ${page.headers.get('location')}`);
  assert.equal(page.headers.get('location'), null);
  assert.ok(html.includes('Sign in to the shepetal app?') && html.includes(`As ${email}`) && html.includes('The Mac or iPhone app on this computer'), 'consent text');
  assert.ok(html.includes('Not you? Use another account'));
  assert.equal(await codes(), 0, 'a GET issues no code');
  assert.match(page.headers.get('content-security-policy') ?? '', /form-action [^;]*shepetal: http:\/\/127\.0\.0\.1:\*/, 'CSP lets the form redirect to the app');
  const got = landing(await consent(login.url, session), MAC);
  assert.equal(got.state, login.state, 'state comes back unchanged');
  assert.match(got.code ?? '', /^[A-Za-z0-9_-]{43}$/, 'code');
  ok(`/app/login signed in: GET is the consent page ("Sign in to the shepetal app?", as ${email}, the Mac or iPhone app) with no code; Continue is 302 to ${MAC}?code=…&state=… (state ${JSON.stringify(got.state)} unchanged)`);

  // ---- 4. The app trades the code for a token, once.
  const grant = await token({ code: got.code, code_verifier: login.verifier, redirect_uri: MAC });
  assert.equal(grant.status, 200, JSON.stringify(grant.body));
  assert.match(grant.body.access_token ?? '', /^[A-Za-z0-9_-]{43}$/, 'access_token');
  assert.equal(grant.body.email, email);
  assert.deepEqual(await token({ code: got.code, code_verifier: login.verifier, redirect_uri: MAC }), { status: 400, body: { error: 'invalid_grant' } }, 'a code is single use');
  ok('app/token: 200 {access_token, email}, then 400 invalid_grant for the same code');
  const accessToken = grant.body.access_token;

  // ---- 5. License: trial for 30 days from the first sign-in.
  let lic = await app('GET', '/api/license', { token: accessToken });
  assert.equal(lic.status, 200, JSON.stringify(lic.body));
  assert.equal(lic.body.status, 'trial');
  assert.equal(lic.body.email, email);
  const [[started]] = await d1(`SELECT trial_started_at FROM users WHERE email = '${email}'`);
  assert.equal(lic.body.trial_ends_at, new Date(Date.parse(started) + 30 * DAY).toISOString(), 'trial_ends_at = first sign-in + 30 days');
  assert.ok(Date.parse(started) >= t0 - 1000 && Date.parse(started) <= Date.now(), 'the trial started at this sign-in');
  assert.equal((await app('GET', '/api/license', { token: 'not-a-token' })).status, 401);
  assert.equal((await app('GET', '/api/license')).status, 401);
  ok(`license: trial until ${lic.body.trial_ends_at} (first sign-in ${started} + 30 days); 401 for a bad or missing token`);

  // ---- 6. Checkout: a Stripe Checkout URL for the chosen plan, on the user's own Stripe customer, codes allowed.
  assert.equal((await app('POST', '/api/checkout', { json: {} })).status, 401, 'checkout signed out');
  assert.equal((await app('POST', '/api/checkout', { token: accessToken, json: { plan: 'yearly' } })).status, 400, 'an unknown plan');
  const calls = (path, method = 'POST') => stripeCalls.filter((c) => c.path === path && c.method === method);
  assert.deepEqual(await app('POST', '/api/checkout', { token: accessToken, json: { plan: 'monthly', code: 'PRODUCTHUNT' } }), { status: 400, body: { error: 'code_lifetime_only', message: 'The code works on the one-time price only.' } });
  const co = await app('POST', '/api/checkout', { token: accessToken, json: { plan: 'monthly' } });
  assert.equal(co.status, 200, JSON.stringify(co.body));
  assert.match(co.body.url, /^https:\/\/checkout\.stripe\.com\//);
  assert.equal(stripeCalls[0].auth, `Bearer ${env.STRIPE_SECRET_KEY}`);
  assert.equal(calls('/v1/prices', 'GET')[0].params['lookup_keys[0]'], 'shepetal_monthly', 'the price is found by lookup_key');
  assert.equal(calls('/v1/customers').length, 1, 'one Stripe customer for the user');
  const subSent = calls('/v1/checkout/sessions')[0].params;
  assert.equal(subSent.mode, 'subscription');
  assert.equal(subSent['line_items[0][price]'], 'price_e2e_shepetal_monthly');
  assert.equal(subSent.allow_promotion_codes, undefined, "Stripe's code field stays off");
  assert.equal(subSent['automatic_tax[enabled]'], 'true', 'Stripe Tax');
  assert.equal(subSent['consent_collection[terms_of_service]'], 'required', 'the EU consent to delivery right away');
  assert.match(subSent['custom_text[terms_of_service_acceptance][message]'] ?? '', /14-day \[right of withdrawal\]\(http:\/\/localhost:\d+\/refunds#withdrawal\)/, 'the withdrawal information is linked');
  assert.equal(subSent.success_url, `${BASE}/account?purchased=1`, 'Stripe URLs follow the site address');
  assert.equal(subSent.customer, 'cus_e2e');
  assert.equal(subSent.client_reference_id, undefined, "no client_reference_id on a subscription: backant's handler would take it");
  assert.equal(subSent['subscription_data[metadata][app]'], 'shepetal');
  const userId = subSent['subscription_data[metadata][user_id]'];
  assert.match(userId ?? '', /^\d+$/, 'the subscription carries the user id');
  ok(`checkout monthly: ${co.body.url} (mode subscription, shepetal_monthly by lookup_key, no code field and a code refused with 400, customer cus_e2e, user ${userId} in the subscription metadata)`);

  // ---- 7. Stripe's webhook. backant.io uses the same Stripe account, so this endpoint also gets
  // backant's checkouts: only shepetal's sessions and subscriptions count, everything else is a 200 no-op.
  const event = (type, object = {}, id = `evt_e2e_${randomBytes(6).toString('hex')}`) =>
    JSON.stringify({
      id,
      object: 'event',
      type,
      api_version: '2025-02-24.acacia',
      created: Math.floor(Date.now() / 1000),
      livemode: false,
      data: {
        object: {
          id: 'cs_test_e2e_1',
          object: 'checkout.session',
          mode: 'payment',
          status: 'complete',
          payment_status: 'paid',
          client_reference_id: userId,
          customer: 'cus_e2e',
          metadata: { app: 'shepetal', user_id: userId, plan: 'lifetime' },
          ...object,
        },
      },
    });
  const hook = (body, secret = env.STRIPE_WEBHOOK_SECRET) => {
    const t = Math.floor(Date.now() / 1000);
    const v1 = createHmac('sha256', secret).update(`${t}.${body}`).digest('hex');
    return fetch(`${BASE}/api/stripe/webhook`, { method: 'POST', headers: { 'content-type': 'application/json', 'stripe-signature': `t=${t},v1=${v1}` }, body });
  };
  const noLicense = async (why, body, status = 200, secret) => {
    const r = await hook(body, secret);
    assert.equal(r.status, status, `${why}: ${await r.text()}`);
    assert.equal((await app('GET', '/api/license', { token: accessToken })).body.status, 'trial', `${why} must not grant a license`);
  };
  await noLicense('a bad signature', event('checkout.session.completed'), 400, 'whsec_wrong');
  // backant's own subscription checkout (backant-mcp), paid, whose client_reference_id happens to equal this user's id.
  await noLicense(
    "backant's subscription checkout",
    event('checkout.session.completed', { mode: 'subscription', metadata: {}, subscription: 'sub_backant', success_url: 'https://backant.io/dashboard/billing?success=1' }),
  );
  await noLicense("backant's subscription update", event('customer.subscription.updated', { ...fakeSub, id: 'sub_backant', metadata: {} }));
  await noLicense('an unpaid shepetal checkout (delayed payment method)', event('checkout.session.completed', { payment_status: 'unpaid' }));
  ok("webhook: bad signature 400; backant's subscription checkout and update, and an unpaid one, 200 with no license");

  // The monthly checkout completes: the webhook reads the subscription from Stripe.
  Object.assign(fakeSub, { metadata: { app: 'shepetal', user_id: userId } });
  const subDone = event('checkout.session.completed', { mode: 'subscription', client_reference_id: null, subscription: 'sub_e2e', metadata: { app: 'shepetal', user_id: userId, plan: 'monthly' } }, 'evt_e2e_sub');
  assert.equal((await hook(subDone)).status, 200);
  lic = await app('GET', '/api/license', { token: accessToken });
  const through = new Date(fakeSub.current_period_end * 1000).toISOString();
  assert.deepEqual(lic.body, { status: 'active', plan: 'subscription', trial_ends_at: null, paid_through: through, renews: true, payment_failed: false, email });
  // Stripe sends an event again when it is not sure it arrived: it changes nothing a second time.
  const retrieves = calls('/v1/subscriptions/sub_e2e', 'GET').length;
  assert.deepEqual(await (await hook(subDone)).json(), { received: true, duplicate: true });
  assert.equal(calls('/v1/subscriptions/sub_e2e', 'GET').length, retrieves, 'a redelivered event is not handled again');
  ok(`webhook: the monthly checkout makes a subscription paid through ${through}, renewing; the same event id again is a no-op`);

  // A second monthly checkout is refused; the Billing Portal opens with shepetal's configuration.
  assert.deepEqual(await app('POST', '/api/checkout', { token: accessToken, json: { plan: 'monthly' } }), { status: 409, body: { error: 'already_subscribed' } });
  const portal = await app('POST', '/api/billing/portal', { token: accessToken });
  assert.deepEqual(portal, { status: 200, body: { url: 'https://billing.stripe.com/p/session/test_e2e' } });
  const ps = calls('/v1/billing_portal/sessions')[0].params;
  assert.deepEqual([ps.customer, ps.configuration, ps.return_url], ['cus_e2e', 'bpc_e2e', `${BASE}/account`]);
  ok('checkout: a second subscription is 409 already_subscribed; billing/portal opens the Billing Portal (cus_e2e, configuration bpc_e2e, back to /account)');

  // A failed renewal: Stripe moves the subscription to past_due and the paid time ends where the new period began.
  Object.assign(fakeSub, { status: 'past_due', current_period_start: Math.floor(Date.now() / 1000) - 60 });
  const inv = { id: 'in_e2e', object: 'invoice', status: 'open', subscription: 'sub_e2e', subscription_details: { metadata: { app: 'shepetal', user_id: userId } } };
  assert.equal((await hook(event('invoice.payment_failed', inv))).status, 200);
  lic = await app('GET', '/api/license', { token: accessToken });
  assert.equal(lic.body.status, 'trial', 'a failed renewal ends the paid time; the trial is still running for this user');
  assert.equal(lic.body.payment_failed, true);
  Object.assign(fakeSub, { status: 'active' });
  assert.equal((await hook(event('invoice.paid', { ...inv, status: 'paid' }))).status, 200);
  lic = await app('GET', '/api/license', { token: accessToken });
  assert.deepEqual([lic.body.status, lic.body.payment_failed], ['active', false]);
  ok('webhook: invoice.payment_failed stops the subscription (payment_failed true), invoice.paid starts it again');

  // A cancel in the Billing Portal: it keeps working to the period end and stops renewing.
  Object.assign(fakeSub, { cancel_at_period_end: true });
  assert.equal((await hook(event('customer.subscription.updated', fakeSub))).status, 200);
  lic = await app('GET', '/api/license', { token: accessToken });
  assert.deepEqual([lic.body.status, lic.body.plan, lic.body.renews], ['active', 'subscription', false]);
  Object.assign(fakeSub, { cancel_at_period_end: false });
  assert.equal((await hook(event('customer.subscription.updated', fakeSub))).status, 200);
  ok('webhook: a cancelled subscription stays active until its period end with renews false; resumed, it renews again');

  // Plan settings: the plan, cancel at period end and resume through the API, the portal as a link.
  Object.assign(fakeSub, { items: { object: 'list', data: [{ price: { unit_amount: 99, currency: 'usd' } }] } });
  assert.equal((await hook(event('customer.subscription.updated', fakeSub))).status, 200);
  let plan = await app('GET', '/api/account/plan', { token: accessToken });
  assert.equal(plan.status, 200, JSON.stringify(plan.body));
  assert.deepEqual(plan.body.subscription, { status: 'active', paid_through: through, next_billing_date: through, ends_at: null, amount: 99, currency: 'usd', amount_display: '$0.99', interval: 'month' });
  assert.deepEqual(plan.body.actions, { cancel: true, resume: false, switch_to_lifetime: true, portal: true, choose_plan: false });
  const cancelled = await app('POST', '/api/billing/cancel', { token: accessToken });
  assert.equal(cancelled.status, 200, JSON.stringify(cancelled.body));
  assert.equal(calls('/v1/subscriptions/sub_e2e').at(-1)?.params.cancel_at_period_end, 'true');
  assert.deepEqual([cancelled.body.settings.status, cancelled.body.settings.subscription.status, cancelled.body.settings.subscription.ends_at], ['active', 'cancels_at_period_end', through]);
  assert.deepEqual([cancelled.body.license.status, cancelled.body.license.renews], ['active', false]);
  assert.equal((await app('GET', '/api/license', { token: accessToken })).body.renews, false, 'the license says it at once');
  assert.deepEqual(await app('POST', '/api/billing/cancel', { token: accessToken }), { status: 404, body: { error: 'no_subscription' } });
  const resumed = await app('POST', '/api/billing/resume', { token: accessToken });
  assert.equal(resumed.body.settings.subscription.status, 'active');

  // § 312k BGB: "Verträge hier kündigen" in the footer leads to /cancel, a static page, and its Jetzt kündigen button
  // cancels with no sign-in (no cookie, no token). The receipt comes at once, the same for every email; the work runs
  // after it (waitUntil): Stripe, the record, and the notice to Pavel (wrangler dev only prints it).
  await check('/cancel: the footer button, a static page, and Jetzt kündigen with no sign-in: the receipt at once, then the subscription ends at period end or on a later date (shown on /account, undone by Resume), every declaration recorded and sent to Pavel; another site, an unknown email and a flood get nothing', async () => {
    assert.match(await (await fetch(`${BASE}/terms`)).text(), /<a [^>]*href="\/cancel"[^>]*>Verträge hier kündigen<\/a>/, 'the footer carries the button');
    const page = await fetch(`${BASE}/cancel`);
    assert.equal(page.status, 200);
    assert.equal(page.headers.get('x-opennext-cache'), 'HIT', '/cancel is served from the prerendered cache');
    assert.match(await page.text(), /<button type="submit"[^>]*>Jetzt kündigen<\/button>/);
    const press = (fields, origin = BASE) =>
      fetch(`${BASE}/api/cancel`, { method: 'POST', redirect: 'manual', headers: { 'content-type': 'application/x-www-form-urlencoded', origin }, body: new URLSearchParams(fields) });
    const updates = () => calls('/v1/subscriptions/sub_e2e');
    const settle = async (what, done) => {
      for (let i = 0; !(await done()); i++) {
        if (i > 100) throw new Error(`not done after 10 s: ${what}`);
        await sleep(100);
      }
    };
    const refused = await press({ email }, 'https://evil.example');
    assert.equal(refused.status, 403, 'a post from another site is refused');
    assert.match(await refused.text(), /was not received/);
    const before = updates().length;
    const sentAt = Date.now();
    const res = await press({ kind: 'ordinary', reason: '', contract: 'monthly', end: 'asap', date: '', email: email.toUpperCase() });
    const receipt = await res.text();
    assert.equal(res.status, 200, receipt);
    assert.match(res.headers.get('content-security-policy') ?? '', /default-src 'self'/, 'worker.ts answers it, with the security headers');
    assert.match(receipt, /Your cancellation is received\.[\s\S]*It will be processed now\./);
    assert.doesNotMatch(receipt, /stops renewing|is cancelled/, 'the receipt claims nothing before it is done');
    assert.match(receipt, /goes to it by email/, 'and says the confirmation goes to the account by email (SES is set up here)');
    const stamp = receipt.match(/Sent with the Jetzt kündigen button on (\d{4}-\d{2}-\d{2}) at (\d{2}:\d{2}:\d{2}) UTC\./);
    assert.ok(stamp && Math.abs(Date.parse(`${stamp[1]}T${stamp[2]}Z`) - sentAt) < 60_000, 'the receipt carries the time it was sent');
    assert.match(receipt, /<a href="data:text\/plain;charset=utf-8,[^"]+" download="shepetal-cancellation-\d{4}-\d{2}-\d{2}\.txt">/, 'and a file to keep');
    await settle('Stripe: cancel at period end', () => updates().length > before);
    assert.equal(updates().length, before + 1, 'one Stripe call, and none for the refused post');
    assert.equal(updates().at(-1)?.params.cancel_at_period_end, 'true', 'Stripe: cancel at period end');
    const l = await app('GET', '/api/license', { token: accessToken });
    assert.deepEqual([l.body.status, l.body.renews, l.body.paid_through], ['active', false, through], 'it works until the end of the paid month');
    const other = 'nobody-e2e@example.com';
    const stranger = await (await press({ email: other })).text();
    const blank = (html, who) => html.replaceAll(who, '@').replaceAll(encodeURIComponent(who), '@').replace(/\d{4}-\d{2}-\d{2}( at |%20at%20)\d{2}(:|%3A)\d{2}(:|%3A)\d{2}/g, 'T');
    assert.equal(blank(stranger, other), blank(receipt, email.toUpperCase()), 'the same page whether the email has an account or not');
    await settle('both recorded', async () => (await d1('SELECT count(*) FROM cancellations'))[0][0] === 2);
    assert.deepEqual(await d1(`SELECT count(*) FROM users WHERE email = '${other}'`), [[0]], 'no account is created');
    assert.deepEqual(await d1('SELECT outcome, ends_at FROM cancellations ORDER BY id'), [['cancelled', through], ['no_account', null]], 'both are recorded, with the end Stripe has');
    const log = () => readFileSync(logFile, 'utf8');
    await settle("Pavel's notices", () => log().includes(`cancel: no_account (UNMATCHED): ${other}`));
    assert.match(log(), /cancel: cancelled: /, 'Pavel is told of the cancellation too');
    // The confirmation goes through SES (the fake here), to the account's own address, never to the stranger's.
    const confirmations = sesCalls.filter((c) => c.body.Content.Simple.Subject.Data === 'Your cancellation of shepetal (Kündigungsbestätigung)');
    assert.deepEqual(confirmations.map((c) => c.body.Destination.ToAddresses), [[email]], 'one confirmation, to the account');
    assert.equal(confirmations[0].body.FromEmailAddress, 'shepetal <support@shepetal.app>');
    assert.equal(confirmations[0].body.Content.Simple.Body.Html, undefined, 'plain text');
    const bad = await press({ email: '' });
    await bad.text(); // an unread body leaves the socket behind (EPIPE on the next request)
    assert.equal(bad.status, 400, 'the email is required');
    assert.equal((await app('POST', '/api/billing/resume', { token: accessToken })).body.settings.subscription.status, 'active', 'Resume on /account undoes it');
    // A later day: Stripe's cancel_at, which /account shows as the end and Resume clears.
    const day = new Date(Date.parse(through) + 20 * 86_400_000).toISOString().slice(0, 10);
    // "As soon as possible" chosen with a date left in the field: the period end, not the date (§ 312k(5)).
    const asap = updates().length;
    await (await press({ end: 'asap', date: day, email })).text();
    await settle('Stripe: asap over a leftover date', () => updates().length > asap);
    assert.deepEqual([updates().at(-1).params.cancel_at_period_end, updates().at(-1).params.cancel_at], ['true', undefined], 'asap wins over the date');
    assert.equal((await app('POST', '/api/billing/resume', { token: accessToken })).body.settings.subscription.status, 'active');
    await (await press({ end: 'date', date: day, email })).text();
    await settle('Stripe: cancel_at', () => updates().at(-1)?.params.cancel_at !== undefined);
    assert.equal(updates().at(-1).params.cancel_at, String(Date.parse(`${day}T23:59:59Z`) / 1000));
    const ending = await app('GET', '/api/account/plan', { token: accessToken });
    assert.deepEqual([ending.body.subscription.status, ending.body.subscription.ends_at, ending.body.subscription.next_billing_date, ending.body.actions.resume], ['cancels_at_period_end', `${day}T23:59:59.000Z`, null, true], '/account shows the date and offers Resume');
    assert.equal((await app('POST', '/api/billing/resume', { token: accessToken })).body.settings.subscription.status, 'active');
    assert.equal(updates().at(-1).params.cancel_at, '', 'Resume clears the date');
    // A flood: at most 5 a minute for one email (and one address), the rest not received.
    const flood = [];
    for (let i = 0; i < 6; i++) flood.push((await press({ email: other })).status);
    assert.ok(flood.includes(429), `over the limit: ${flood}`);
  });
  await check('/account, subscriber: status, next charge, Manage billing, Switch to lifetime, Cancel subscription with a confirmation', async () => {
    const t = await accountText();
    for (const s of ['$0.99 a month.', 'Monthly', 'Active', 'Next charge', 'Manage billing', 'Switch to lifetime', 'Cancel subscription', 'Cancel your subscription?', 'nothing is charged again'])
      assert.ok(t.includes(s), `subscriber account shows ${s}`);
    assert.ok(!t.includes('Buy once'), 'no plan choice while subscribed');
  });
  const link = await fetch(`${BASE}/api/billing/portal`, { redirect: 'manual', headers: { authorization: `Bearer ${accessToken}` } });
  assert.deepEqual([link.status, link.headers.get('location')], [303, 'https://billing.stripe.com/p/session/test_e2e']);
  assert.equal((await app('GET', '/api/account/plan')).status, 401);
  ok('plan settings: GET /api/account/plan (active, next billing date, $0.99), cancel at period end, resume, GET /api/billing/portal redirects to the portal');

  // Switch to lifetime: bought while subscribed, the subscription ends at once with no further charge.
  assert.deepEqual((await app('POST', '/api/checkout', { token: accessToken, json: { plan: 'lifetime', code: 'PRODUCTHUNT100' } })).body.error, 'invalid_code', "backant's codes never work");
  const lt = await app('POST', '/api/checkout', { token: accessToken, json: { plan: 'lifetime', code: 'PRODUCTHUNT' } });
  assert.equal(lt.status, 200, JSON.stringify(lt.body));
  const sent = calls('/v1/checkout/sessions').at(-1).params;
  assert.equal(sent.mode, 'payment');
  assert.equal(sent['line_items[0][price]'], 'price_e2e_shepetal_lifetime');
  assert.equal(sent['line_items[0][quantity]'], '1');
  assert.equal(sent.allow_promotion_codes, undefined);
  assert.equal(sent['discounts[0][promotion_code]'], 'promo_e2e_PRODUCTHUNT', 'the code is on the session');
  assert.equal(sent.customer, 'cus_e2e');
  assert.equal(sent.client_reference_id, userId, 'client_reference_id is the user id');
  assert.equal(calls('/v1/customers').length, 1, 'the same Stripe customer again');
  const paid = await hook(event('checkout.session.completed', { client_reference_id: sent.client_reference_id, metadata: metadataOf(sent) }));
  assert.equal(paid.status, 200, await paid.clone().text());
  // § 356(6) Nr. 2 d BGB: the purchase is confirmed after the answer, through SES (the fake here) to the buyer's account.
  const purchased = () => sesCalls.filter((c) => c.body.Content.Simple.Subject.Data === 'Your shepetal lifetime license (Bestellbestätigung)');
  for (let i = 0; !purchased().length; i++) {
    if (i > 100) throw new Error('no purchase confirmation after 10 s');
    await sleep(100);
  }
  assert.deepEqual(purchased().map((c) => c.body.Destination.ToAddresses), [[email]], 'one purchase confirmation, to the buyer');
  assert.ok(!readFileSync(logFile, 'utf8').includes(`purchase: confirmation not sent: ${email}`), 'and no hand-off to Pavel');
  lic = await app('GET', '/api/license', { token: accessToken });
  assert.deepEqual(lic.body, { status: 'active', plan: 'lifetime', trial_ends_at: null, paid_through: null, renews: false, payment_failed: false, email });
  assert.equal(calls('/v1/subscriptions/sub_e2e', 'DELETE').length, 1, 'the subscription is cancelled now');
  assert.deepEqual(calls('/v1/subscriptions/sub_e2e', 'DELETE')[0].params, { invoice_now: 'false', prorate: 'false' }, 'no final invoice, no proration');
  plan = await app('GET', '/api/account/plan', { token: accessToken });
  assert.deepEqual([plan.body.plan, plan.body.subscription, plan.body.actions.cancel], ['lifetime', null, false]);
  assert.deepEqual(await app('POST', '/api/checkout', { token: accessToken, json: {} }), { status: 409, body: { error: 'already_active' } });
  await check('/account, lifetime: "Yours forever." and no subscription controls', async () => {
    const t = await accountText();
    for (const s of ['Yours forever.', 'Lifetime', 'Download for Mac']) assert.ok(t.includes(s), `lifetime account shows ${s}`);
    for (const s of ['Cancel subscription', 'Switch to lifetime', 'Manage billing', 'Next charge', 'Buy once']) assert.ok(!t.includes(s), `no ${s} for lifetime`);
  });

  ok(`switch to lifetime: mode payment, shepetal_lifetime, client_reference_id ${userId}; the paid webhook makes it lifetime and cancels the subscription now (no invoice, no proration); checkout is 409 after`);

  // ---- Analytics (POSTHOG_KEY set), all from the Worker, none in the browser: $pageview for a browser's GET of a page
  // (not for RSC, prefetches, bots or the API), download_served (with the version and ?ref=, not for HEAD or bots),
  // appcast_check, license_first_call, checkout_completed and the app sign-in funnel, each tagged app=shepetal, under
  // hashed ids (the daily v_ id the same for a page view and a download), and never an email, an IP or a full referrer.
  await check('analytics on the server: no script or meta in the page; $pageview, download_served (version, ref, utm), appcast_check, license_first_call, checkout_completed and app_login_* reach PostHog tagged app=shepetal, with no email, IP or full referrer', async () => {
    const browser = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
    const ua = { 'user-agent': browser };
    const res = await fetch(`${BASE}/faq?ref=e2e-page&utm_source=e2e&state=private`, { headers: { ...ua, referer: 'https://news.example.org/item?id=4242' } });
    const html = await res.text();
    assert.doesNotMatch(html, /shepetal-analytics|posthog/i, 'no analytics meta or script in the page');
    assert.match(res.headers.get('content-security-policy') ?? '', /connect-src 'self';/, 'the page may connect to the site only');
    // The browser chunks the page loads carry no PostHog either.
    for (const src of [...html.matchAll(/<script[^>]*src="(\/_next\/[^"]+)"/g)].map((m) => m[1])) {
      assert.doesNotMatch(await (await fetch(`${BASE}${src}`)).text(), /posthog/i, src);
    }
    // What a browser's router and bots send: none of it is a page view.
    await (await fetch(`${BASE}/faq?ref=e2e-rsc`, { headers: { ...ua, rsc: '1' } })).text();
    await (await fetch(`${BASE}/faq?ref=e2e-prefetch`, { headers: { ...ua, rsc: '1', 'next-router-prefetch': '1' } })).text();
    await (await fetch(`${BASE}/faq?ref=e2e-bot`, { headers: { 'user-agent': 'Slackbot-LinkExpanding 1.0' } })).text();
    await (await fetch(`${BASE}/faq?ref=e2e-head`, { method: 'HEAD', headers: ua })).text();
    await fetch(`${BASE}/download?ref=producthunt&utm_source=e2e`, { redirect: 'manual', headers: ua });
    await fetch(`${BASE}/download?ref=e2e-head`, { method: 'HEAD', redirect: 'manual', headers: ua });
    await fetch(`${BASE}/download?ref=e2e-bot`, { redirect: 'manual', headers: { 'user-agent': 'facebookexternalhit/1.1' } });
    await fetch(`${BASE}/appcast.xml`, { headers: { 'user-agent': 'shepetal/0.0.3 Sparkle/2.6.4' } });
    // The app opens /app/login in a browser (signed in: the consent page), and the user presses Continue.
    const l = pkce();
    const page = await fetch(`${l.url}&app_version=0.0.3`, { redirect: 'manual', headers: { ...ua, cookie: session, 'sec-fetch-site': 'none' } });
    assert.equal(page.status, 200, `consent page: ${page.status}`);
    const jar = [session, ...page.headers.getSetCookie().map((c) => c.split(';')[0])].join('; ');
    landing(await fetch(`${BASE}/app/login`, {
      method: 'POST',
      redirect: 'manual',
      headers: { ...ua, cookie: jar, origin: BASE, 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams(formOf(await page.text())),
    }), MAC);
    const find = async (event, also = () => true) => {
      for (let i = 0; i < 40; i++) {
        const e = phEvents.find((x) => x.event === event && also(x));
        if (e) return e;
        await sleep(100);
      }
      throw new Error(`no ${event} (got ${phEvents.map((x) => x.event).join(', ') || 'nothing'})`);
    };
    const view = await find('$pageview', (x) => x.properties.ref === 'e2e-page');
    assert.match(view.distinct_id, /^v_[0-9a-f]{32}$/);
    assert.deepEqual(
      [view.properties.app, view.properties.path, view.properties.$current_url, view.properties.$referring_domain, view.properties.utm_source, view.properties.$device_type, view.properties.$os, view.properties.$geoip_disable],
      ['shepetal', '/faq', `${BASE}/faq?ref=e2e-page&utm_source=e2e`, 'news.example.org', 'e2e', 'Desktop', 'Mac OS X', true],
    );
    const dl = await find('download_served', (x) => x.properties.ref === 'producthunt');
    assert.equal(dl.api_key, 'phc_e2e');
    assert.equal(dl.distinct_id, view.distinct_id, 'the page view and the download are the same visitor that day');
    assert.deepEqual([dl.properties.app, dl.properties.version, dl.properties.ref, dl.properties.utm_source, dl.properties.$process_person_profile], ['shepetal', '0.0.1', 'producthunt', 'e2e', false]);
    const opened = await find('app_login_opened', (x) => x.properties.app_version === '0.0.3');
    const consented = await find('app_login_consented', (x) => x.distinct_id === opened.distinct_id);
    assert.match(opened.distinct_id, /^v_[0-9a-f]{32}$/, 'the app sign-in is counted under the anonymous visitor, never the account');
    assert.deepEqual([opened.properties.client, opened.properties.signed_in, consented.properties.client, consented.distinct_id], ['app', true, 'app', opened.distinct_id]);
    const feed = await find('appcast_check', (x) => x.properties.app_version === '0.0.3');
    assert.deepEqual([feed.properties.app, feed.properties.app_version], ['shepetal', '0.0.3']);
    const install = await find('license_first_call');
    assert.match(install.distinct_id, /^u_[0-9a-f]{32}$/);
    assert.deepEqual([install.properties.app, install.properties.$set], ['shepetal', { app: 'shepetal' }]);
    assert.equal(phEvents.filter((x) => x.event === 'license_first_call').length, 1, 'only the first license check is an install');
    const monthly = await find('checkout_completed', (x) => x.properties.plan === 'monthly');
    const paid = await find('checkout_completed', (x) => x.properties.plan === 'lifetime');
    assert.deepEqual([paid.properties.app, paid.distinct_id, monthly.distinct_id], ['shepetal', install.distinct_id, install.distinct_id]);
    assert.equal(phEvents.filter((x) => x.event === 'checkout_completed').length, 2, 'a redelivered checkout is not counted again');
    await sleep(500); // what should not be counted has had the same time to arrive
    const refs = phEvents.map((x) => x.properties.ref).filter(Boolean);
    for (const r of ['e2e-rsc', 'e2e-prefetch', 'e2e-bot', 'e2e-head']) assert.ok(!refs.includes(r), `${r} is not counted`);
    assert.equal(phEvents.filter((x) => x.event === '$pageview' && x.properties.ref === 'e2e-page').length, 1, 'one page view per page');
    const all = JSON.stringify(phEvents);
    for (const leak of [email, '127.0.0.1', 'example.com', '4242', 'private', 'Chrome/131', l.state]) assert.ok(!all.includes(leak), `${leak} is not sent`);
  });

  // ---- 8. Consent: a program that opens /app/login by itself must not get a code without the user.
  await check('/app/login POST: no code without the CSRF token, with a wrong one, cross-site, or signed out', async () => {
    const before = await codes();
    const refused = [
      ['no CSRF field', { fields: { csrf: null } }, 403],
      ['a wrong CSRF token', { fields: { csrf: b64url(randomBytes(32)) } }, 403],
      ['no CSRF cookie', { cookies: false }, 403],
      ['a cross-site Origin', { origin: 'https://evil.example' }, 403],
      ['no Origin', { origin: null }, 403],
      ['a redirect_uri swapped in the form', { fields: { redirect_uri: 'http://127.0.0.1.evil.com/callback' } }, 400],
    ];
    for (const [why, opts, status] of refused) {
      const r = await consent(pkce().url, session, opts);
      assert.equal(r.status, status, `${why}: ${r.status} ${r.headers.get('location')}`);
      assert.equal(r.headers.get('location'), null, why);
    }
    // Signed out at POST time: a valid CSRF pair but no session.
    const page = await browse(pkce().url, session);
    const csrfCookie = page.headers.getSetCookie().map((c) => c.split(';')[0]).join('; ');
    const r = await fetch(`${BASE}/app/login`, {
      method: 'POST',
      redirect: 'manual',
      headers: { cookie: csrfCookie, origin: BASE, 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams(formOf(await page.text())),
    });
    assert.equal(r.status, 401, `signed out: ${r.status}`);
    assert.equal(await codes(), before, 'no code was issued');
  });
  await check('/app/login: "Not you? Use another account" goes to Google with the account chooser, then back to the same login', async () => {
    const l = pkce();
    const r = await browse(`${l.url}&switch=1`, session);
    const to = new URL(r.headers.get('location') ?? 'about:blank');
    assert.equal(to.origin, 'https://accounts.google.com', `${r.status} ${to}`);
    assert.equal(to.searchParams.get('prompt'), 'select_account');
    const back = r.headers.getSetCookie().find((c) => c.startsWith('authjs.callback-url='));
    assert.equal(decodeURIComponent(back?.split(';')[0].split('=')[1] ?? ''), l.url);
  });

  // ---- 9. The redirect_uri allowlist and PKCE on the running Worker (more cases in app-login.test.ts).
  await check('/app/login: only shepetal://auth and http://127.0.0.1:<port>/callback, exactly; anything else 400 and no code', async () => {
    const loopback = pkce('http://127.0.0.1:53682/callback');
    assert.equal(landing(await consent(loopback.url, session), loopback.redirect_uri).state, loopback.state);
    for (const uri of [
      'shepetal://auth.evil',
      'shepetal://auth/',
      'shepetal://auth#x',
      'http://127.0.0.1.evil.com/callback',
      'http://127.0.0.1.evil.com:53682/callback',
      'http://localhost:53682/callback',
      'http://user@127.0.0.1:53682/callback',
      'http://127.0.0.1:53682@evil.com/callback',
      'http://127.0.0.1:53682/callback#x',
      'http://127.0.0.1:53682/callback?x=1',
      'https://evil.com/callback',
    ]) {
      for (const cookie of [session, undefined]) {
        const r = await browse(pkce(uri).url, cookie);
        assert.equal(r.status, 400, `${uri} ${cookie ? 'signed in' : 'signed out'}: ${r.status} ${r.headers.get('location')}`);
        assert.equal(r.headers.get('location'), null);
      }
    }
  });
  await check('/app/login: S256 only, a 43-character challenge and a state are required', async () => {
    const l = pkce();
    for (const [k, v] of [['code_challenge_method', 'plain'], ['code_challenge_method', ''], ['code_challenge', 'short'], ['state', '']]) {
      const u = new URL(l.url);
      u.searchParams.set(k, v);
      assert.equal((await browse(u.href, session)).status, 400, `${k}=${v}`);
    }
  });
  await check('app/token: a wrong verifier is invalid_grant and spends the code', async () => {
    const l = pkce();
    const { code } = landing(await consent(l.url, session), MAC);
    assert.deepEqual(await token({ code, code_verifier: b64url(randomBytes(32)), redirect_uri: MAC }), { status: 400, body: { error: 'invalid_grant' } });
    assert.equal((await token({ code, code_verifier: l.verifier, redirect_uri: MAC })).status, 400, 'no retry after a wrong verifier');
  });
  await check('app/token: a redirect_uri other than the one given to /app/login is invalid_grant', async () => {
    const l = pkce();
    const { code } = landing(await consent(l.url, session), MAC);
    assert.deepEqual(await token({ code, code_verifier: l.verifier, redirect_uri: 'http://127.0.0.1:53682/callback' }), { status: 400, body: { error: 'invalid_grant' } });
  });
  await check('app/token: a code lives 60 s; an expired one is invalid_grant', async () => {
    const l = pkce();
    const { code } = landing(await consent(l.url, session), MAC);
    const [[ttl]] = await d1("SELECT (julianday(expires_at) - julianday('now')) * 86400 FROM app_codes ORDER BY expires_at DESC LIMIT 1");
    assert.ok(ttl > 55 && ttl <= 60, `the newest code lives ${ttl} s`);
    await d1("UPDATE app_codes SET expires_at = '2000-01-01T00:00:00.000Z'");
    assert.deepEqual(await token({ code, code_verifier: l.verifier, redirect_uri: MAC }), { status: 400, body: { error: 'invalid_grant' } });
  });
  await check('app/token: a missing field is invalid_request; D1 holds only the hash of a code', async () => {
    assert.deepEqual(await token({ code: 'x', redirect_uri: MAC }), { status: 400, body: { error: 'invalid_request' } });
    const { code } = landing(await consent(pkce().url, session), MAC);
    assert.ok(!JSON.stringify(await d1('SELECT * FROM app_codes')).includes(code), 'the raw code is not in D1');
  });

  // ---- 10. Token lifetime: 90 days from the last use; Sign out revokes.
  const freshToken = async () => {
    const l = pkce();
    const { code } = landing(await consent(l.url, session), MAC);
    return (await token({ code, code_verifier: l.verifier, redirect_uri: MAC })).body.access_token;
  };
  await check('a token unused for 90 days gets 401; one used within 90 days works and its 90 days start again', async () => {
    const [old, recent] = [await freshToken(), await freshToken()];
    const lastUse = (t, days) => {
      const at = new Date(Date.now() - days * DAY).toISOString();
      return d1(`UPDATE tokens SET created_at = '${at}', last_used_at = '${at}' WHERE hash = '${createHash('sha256').update(t).digest('hex')}'`);
    };
    await lastUse(old, 91);
    await lastUse(recent, 89);
    assert.equal((await app('GET', '/api/license', { token: old })).status, 401, 'unused for 91 days');
    assert.equal((await app('GET', '/api/license', { token: recent })).status, 200, 'used 89 days ago');
    const [[last]] = await d1(`SELECT last_used_at FROM tokens WHERE hash = '${createHash('sha256').update(recent).digest('hex')}'`);
    assert.ok(Date.now() - Date.parse(last) < 60_000, `the use moved last_used_at to now: ${last}`);
  });
  await check('app/revoke (Sign out): 200, then the token gets 401 on license and checkout', async () => {
    assert.equal((await app('POST', '/api/app/revoke')).status, 401, 'no token');
    const r = await app('POST', '/api/app/revoke', { token: accessToken });
    assert.deepEqual([r.status, r.body], [200, { ok: true }]);
    assert.equal((await app('GET', '/api/license', { token: accessToken })).status, 401);
    assert.equal((await app('POST', '/api/checkout', { token: accessToken, json: {} })).status, 401);
  });

  // ---- 11. The trial emails: the Cron Trigger (wrangler dev --test-scheduled) sends through the fake SES.
  const cron = async () => {
    const before = sesCalls.length;
    const r = await fetch(`${BASE}/__scheduled?cron=${encodeURIComponent('*/15 * * * *')}`);
    assert.equal(r.status, 200, `/__scheduled: ${r.status}`);
    // The sends run in waitUntil, after the answer.
    for (let i = 0; i < 20 && (await d1("SELECT COUNT(*) FROM lifecycle_emails WHERE status = 'sending'"))[0][0] > 0; i++) await sleep(250);
    await sleep(500);
    return sesCalls.slice(before);
  };
  const at = (days) => new Date(Date.now() - days * DAY).toISOString();
  await check('cron: welcome to a new trial, day 25 to a trial user and never to a lifetime owner, signed, nothing twice', async () => {
    await d1(`UPDATE users SET trial_started_at = '${at(10)}'`); // everyone signed in above is between windows
    await d1(`INSERT INTO users (email, trial_started_at) VALUES ('fresh@example.com', '${at(0.01)}'), ('ending@example.com', '${at(25.2)}')`);
    await d1(`INSERT INTO users (email, trial_started_at, status, plan) VALUES ('owner@example.com', '${at(25.2)}', 'active', 'lifetime')`);
    const sent = await cron();
    assert.deepEqual(sent.map((c) => [c.body.Destination.ToAddresses[0], c.body.Content.Simple.Subject.Data]).sort(), [
      ['ending@example.com', 'Your shepetal trial ends in 5 days'],
      ['fresh@example.com', 'Welcome to shepetal'],
    ]);
    for (const c of sent) {
      assert.match(c.auth, /^AWS4-HMAC-SHA256 Credential=AKIDE2E\/\d{8}\/eu-central-1\/ses\/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=[0-9a-f]{64}$/);
      assert.equal(c.body.FromEmailAddress, 'shepetal <hello@shepetal.app>');
      assert.deepEqual(c.body.ReplyToAddresses, ['support@shepetal.app']);
      assert.ok(c.body.Content.Simple.Body.Html.Data.startsWith('<!doctype html>'));
    }
    assert.deepEqual(await cron(), [], 'the next run sends nothing again');
    const rows = await d1("SELECT kind, status, message_id FROM lifecycle_emails ORDER BY kind");
    assert.deepEqual(rows.map((r) => r.slice(0, 2)), [['day25', 'sent'], ['welcome', 'sent']]);
  });
  await check('unsubscribe: the List-Unsubscribe link asks on GET, unsubscribes on the one-click POST, refuses a forged one', async () => {
    const welcome = sesCalls.find((c) => c.body.Destination.ToAddresses[0] === 'fresh@example.com');
    const link = welcome.body.Content.Simple.Headers.find((h) => h.Name === 'List-Unsubscribe').Value.slice(1, -1);
    assert.deepEqual(welcome.body.Content.Simple.Headers.find((h) => h.Name === 'List-Unsubscribe-Post'), { Name: 'List-Unsubscribe-Post', Value: 'List-Unsubscribe=One-Click' });
    const local = `${BASE}${new URL(link).pathname}${new URL(link).search}`;
    const ask = await fetch(local);
    assert.equal(ask.status, 200);
    assert.match(await ask.text(), /<form method="post"/);
    assert.match(ask.headers.get('content-security-policy') ?? '', /frame-ancestors 'none'/, 'the security headers, as on every native answer');
    const [[id]] = await d1("SELECT id FROM users WHERE email = 'fresh@example.com'");
    assert.equal((await d1(`SELECT COUNT(*) FROM email_unsubscribes WHERE user_id = ${id}`))[0][0], 0, 'GET changed nothing');
    const forged = local.replace(/u=\d+/, `u=${id + 1}`);
    assert.equal((await fetch(forged, { method: 'POST', body: 'List-Unsubscribe=One-Click', headers: { 'content-type': 'application/x-www-form-urlencoded' } })).status, 400);
    const done = await fetch(local, { method: 'POST', body: 'List-Unsubscribe=One-Click', headers: { 'content-type': 'application/x-www-form-urlencoded' } });
    assert.equal(done.status, 200);
    assert.equal((await d1(`SELECT COUNT(*) FROM email_unsubscribes WHERE user_id = ${id}`))[0][0], 1);
    await d1(`UPDATE users SET trial_started_at = '${at(3.1)}' WHERE id = ${id}`); // day 3 is due now, but they left
    assert.deepEqual(await cron(), [], 'no tip after unsubscribing');
  });
}

try {
  await main();
} catch (e) {
  failed.push('main');
  console.log(`not ok ${++step} - ${e.message.split('\n').join('\n    ')}`);
  try {
    const lines = readFileSync(logFile, 'utf8').trim().split('\n');
    console.log(`--- last lines of wrangler dev:\n${lines.slice(-40).join('\n')}`);
  } catch {}
} finally {
  if (worker?.exitCode === null) {
    try {
      process.kill(-worker.pid, 'SIGTERM');
    } catch {}
  }
  fakeStripe.close();
  await sleep(300);
  rmSync(tmp, { recursive: true, force: true });
}
console.log(failed.length ? `e2e: FAILED (${failed.length} of ${step})` : `e2e: OK (${step} steps, ${Math.round((Date.now() - t0) / 1000)} s)`);
process.exit(failed.length ? 1 : 0);
