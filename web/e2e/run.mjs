#!/usr/bin/env node
// End-to-end login test for the account service (API.md), on the real Worker runtime.
//
// It builds the Worker (opennextjs-cloudflare build), applies migrations/ to a fresh local D1,
// starts `wrangler dev` on 127.0.0.1 and a fake Stripe API, then signs in the way the apps do
// (OAuth for native apps with PKCE): GET /app/login signed out goes to Google and comes back,
// signed in it redirects to shepetal://auth with a one-time code, POST /api/app/token trades it
// for a token, license = trial, checkout per plan = a Stripe Checkout URL, signed webhooks for the
// subscription (paid, failed, cancelled), the Billing Portal, then the lifetime license. Then the redirect_uri and PKCE rules.
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
const fakeStripe = createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    const url = new URL(req.url, 'http://x');
    const params = { ...Object.fromEntries(url.searchParams), ...Object.fromEntries(new URLSearchParams(req.method === 'GET' ? '' : body)) };
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
      if (params.cancel_at_period_end) fakeSub.cancel_at_period_end = params.cancel_at_period_end === 'true';
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
    // The flag: @opennextjs/cloudflare refuses Next 15.5 as past its support window. A test build only;
    // npm run deploy keeps refusing until Next is upgraded.
    execFileSync(join(BIN, 'opennextjs-cloudflare'), ['build', '--dangerouslyUseUnsupportedNextVersion'], { cwd: WEB, stdio: ['ignore', 'pipe', 'inherit'] });
    ok('opennextjs-cloudflare build');
  }
  const state = join(tmp, 'state');
  wrangler(['d1', 'migrations', 'apply', 'DB', '--local', '--persist-to', state]);
  ok('migrations applied to a fresh local D1');

  const log = createWriteStream(logFile);
  // --local-upstream: with the custom-domain route in wrangler.toml, wrangler dev otherwise rewrites Host and
  // Origin to shepetal.backant.io, and the consent POST fails its Origin check against AUTH_URL with a 403.
  worker = spawn(
    join(BIN, 'wrangler'),
    ['dev', '--ip', '127.0.0.1', '--port', String(port), '--inspector-port', String(await freePort()),
      '--local-upstream', `localhost:${port}`,
      '--persist-to', state, '--env-file', envFile, '--show-interactive-dev-session=false'],
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

  // ---- 0. The landing page renders on the Worker, starts the trial with the sign-in form and
  // loads every script, style, font and image from the site itself (no trackers, no font CDN).
  await check('landing page: sign-in form, nothing loaded from another server, fonts only from self', async () => {
    const res = await fetch(`${BASE}/`);
    const html = await res.text();
    assert.equal(res.status, 200);
    assert.ok(html.includes('Try 30 days free') && /<form[^>]*action=/.test(html), 'the trial button is a sign-in form');
    // Assets (src, srcset, stylesheets, preloads) and visible links; the canonical <link> names the site's own domain.
    const outside = [
      ...html.matchAll(/\b(?:src|srcset)="(https?:\/\/[^"]+)"/g),
      ...html.matchAll(/<(?:a|link(?![^>]*rel="(?:canonical|alternate)"))\b[^>]*\bhref="(https?:\/\/[^"]+)"/g),
    ].map((m) => m[1]);
    assert.deepEqual(outside, [], 'no asset or link to another server');
    assert.match(res.headers.get('content-security-policy') ?? '', /font-src 'self' data:/);
    // The X card: a large image at an absolute URL, served as a static file.
    assert.match(html, /<meta property="og:image" content="https:\/\/[^"]+\/og\.jpg"/);
    assert.match(html, /<meta name="twitter:card" content="summary_large_image"/);
    const og = await fetch(`${BASE}/og.jpg`);
    assert.equal(og.status, 200);
    assert.match(og.headers.get('content-type') ?? '', /^image\/jpeg/);
    // The footer's Legal link carries the attribution and trademark notices the page no longer prints.
    assert.ok(html.includes('href="/legal"'), 'the footer links to /legal');
    const legal = await fetch(`${BASE}/legal`);
    assert.equal(legal.status, 200);
    assert.ok((await legal.text()).includes('/brand/emoji/NOTICE.txt'), '/legal links the Noto NOTICE');
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

  // ---- 2. Fake the Google sign-in: a next-auth JWT session cookie, as the callback would set it.
  const email = `e2e-${randomBytes(4).toString('hex')}@example.com`;
  const session = await sessionFor(email);
  const me = await (await fetch(`${BASE}/api/auth/session`, { headers: { cookie: session } })).json();
  assert.equal(me?.user?.email, email, 'the test session is accepted');
  ok(`test session for ${email}`);

  // ---- 3. Signed in, a GET shows the consent page and issues nothing; Continue (a POST) redirects
  // to the app with a one-time code and the state unchanged.
  const codes = async () => (await d1('SELECT count(*) FROM app_codes'))[0][0];
  const page = await browse(login.url, session);
  const html = await page.text();
  assert.equal(page.status, 200, `consent page: ${page.status} ${page.headers.get('location')}`);
  assert.equal(page.headers.get('location'), null);
  assert.ok(html.includes(`Sign in to the Shepetal app on this computer as ${email}?`) && html.includes('Mac or iPhone app'), 'consent text');
  assert.ok(html.includes('Not you? Use another account'));
  assert.equal(await codes(), 0, 'a GET issues no code');
  assert.match(page.headers.get('content-security-policy') ?? '', /form-action [^;]*shepetal: http:\/\/127\.0\.0\.1:\*/, 'CSP lets the form redirect to the app');
  const got = landing(await consent(login.url, session), MAC);
  assert.equal(got.state, login.state, 'state comes back unchanged');
  assert.match(got.code ?? '', /^[A-Za-z0-9_-]{43}$/, 'code');
  ok(`/app/login signed in: GET is the consent page ("…as ${email}?", Mac or iPhone app) with no code; Continue is 302 to ${MAC}?code=…&state=… (state ${JSON.stringify(got.state)} unchanged)`);

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
  assert.deepEqual([cancelled.body.status, cancelled.body.subscription.status, cancelled.body.subscription.ends_at], ['active', 'cancels_at_period_end', through]);
  assert.deepEqual(await app('POST', '/api/billing/cancel', { token: accessToken }), { status: 409, body: { error: 'no_renewing_subscription' } });
  const resumed = await app('POST', '/api/billing/resume', { token: accessToken });
  assert.equal(resumed.body.subscription.status, 'active');
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
  lic = await app('GET', '/api/license', { token: accessToken });
  assert.deepEqual(lic.body, { status: 'active', plan: 'lifetime', trial_ends_at: null, paid_through: null, renews: false, payment_failed: false, email });
  assert.equal(calls('/v1/subscriptions/sub_e2e', 'DELETE').length, 1, 'the subscription is cancelled now');
  assert.deepEqual(calls('/v1/subscriptions/sub_e2e', 'DELETE')[0].params, { invoice_now: 'false', prorate: 'false' }, 'no final invoice, no proration');
  plan = await app('GET', '/api/account/plan', { token: accessToken });
  assert.deepEqual([plan.body.plan, plan.body.subscription, plan.body.actions.cancel], ['lifetime', null, false]);
  assert.deepEqual(await app('POST', '/api/checkout', { token: accessToken, json: {} }), { status: 409, body: { error: 'already_active' } });
  ok(`switch to lifetime: mode payment, shepetal_lifetime, client_reference_id ${userId}; the paid webhook makes it lifetime and cancels the subscription now (no invoice, no proration); checkout is 409 after`);

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
