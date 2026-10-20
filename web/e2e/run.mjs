#!/usr/bin/env node
// End-to-end login test for the account service (API.md), on the real Worker runtime.
//
// It builds the Worker (opennextjs-cloudflare build), applies migrations/ to a fresh local D1,
// starts `wrangler dev` on 127.0.0.1 and a fake Stripe API, then signs in the way the Mac app
// does (Sources/ShepetalCore/Account.swift): device start, approve on /device as a signed-in user,
// poll the token at `interval`, license = trial, checkout = a Stripe Checkout URL, a signed
// checkout.session.completed webhook, license = active.
//
// Google is faked with a next-auth session cookie signed with the run's AUTH_SECRET, so the run
// needs no Google account and no network except Google's OIDC discovery (for the sign-in redirect).
// No real secret is read: every value is generated per run.
//
//   npm run e2e                 # from web/
//   E2E_SKIP_BUILD=1 npm run e2e  # reuse .open-next/ from the last build
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { createHmac, randomBytes } from 'node:crypto';
import { createWriteStream, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { encode } from 'next-auth/jwt';

const WEB = join(dirname(fileURLToPath(import.meta.url)), '..');
const WRANGLER = join(WEB, 'node_modules', '.bin', 'wrangler');
const DAY = 86_400_000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const tmp = mkdtempSync(join(tmpdir(), 'shepetal-e2e-'));
const t0 = Date.now();
let step = 0;
const ok = (msg) => console.log(`ok ${++step} - ${msg}`);
// Stripe form params `metadata[app]=x` -> {app: 'x'}.
const metadataOf = (params) =>
  Object.fromEntries(Object.entries(params).flatMap(([k, v]) => (k.startsWith('metadata[') ? [[k.slice(9, -1), v]] : [])));

const freePort = () =>
  new Promise((resolve) => {
    const s = createServer().listen(0, '127.0.0.1', () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });

// ---- Fake Stripe API: just the one call /api/checkout makes. Anything else is a test failure.
const stripeCalls = [];
const fakeStripe = createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    const params = Object.fromEntries(new URLSearchParams(body));
    stripeCalls.push({ method: req.method, path: req.url, params, auth: req.headers.authorization });
    res.setHeader('content-type', 'application/json');
    if (req.method !== 'POST' || req.url !== '/v1/checkout/sessions') {
      res.statusCode = 404;
      return res.end(JSON.stringify({ error: { type: 'invalid_request_error', message: `fake Stripe: no ${req.method} ${req.url}` } }));
    }
    const id = `cs_test_e2e_${stripeCalls.length}`;
    res.end(
      JSON.stringify({
        id,
        object: 'checkout.session',
        mode: params.mode,
        status: 'open',
        payment_status: 'unpaid',
        client_reference_id: params.client_reference_id ?? null,
        customer_email: params.customer_email ?? null,
        metadata: metadataOf(params),
        url: `https://checkout.stripe.com/c/pay/${id}`,
      }),
    );
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
  STRIPE_PRICE_ID: 'price_e2e_lifetime',
  STRIPE_API_BASE: `http://127.0.0.1:${fakeStripe.address().port}`,
};
// An env file instead of --var keeps values out of `ps`, and replaces any developer .dev.vars.
const envFile = join(tmp, 'e2e.env');
writeFileSync(envFile, Object.entries(env).map(([k, v]) => `${k}=${v}`).join('\n') + '\n', { mode: 0o600 });

let worker;
const logFile = join(tmp, 'wrangler.log');
function teardown() {
  if (worker && worker.exitCode === null) {
    try {
      process.kill(-worker.pid, 'SIGTERM');
    } catch {}
  }
  fakeStripe.close();
}

async function main() {
  const run = (args) => execFileSync(WRANGLER, args, { cwd: WEB, stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, CI: '1' } });
  if (!process.env.E2E_SKIP_BUILD) {
    execFileSync(join(WEB, 'node_modules', '.bin', 'opennextjs-cloudflare'), ['build'], { cwd: WEB, stdio: ['ignore', 'pipe', 'inherit'] });
    ok('opennextjs-cloudflare build');
  }
  const state = join(tmp, 'state');
  run(['d1', 'migrations', 'apply', 'DB', '--local', '--persist-to', state]);
  ok('migrations applied to a fresh local D1');

  const inspector = await freePort();
  const log = createWriteStream(logFile);
  worker = spawn(
    WRANGLER,
    ['dev', '--ip', '127.0.0.1', '--port', String(port), '--inspector-port', String(inspector),
      '--persist-to', state, '--env-file', envFile, '--show-interactive-dev-session=false'],
    { cwd: WEB, detached: true, stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, CI: '1' } },
  );
  worker.stdout.pipe(log);
  worker.stderr.pipe(log);
  for (let i = 0; ; i++) {
    if (worker.exitCode !== null) throw new Error(`wrangler dev exited with ${worker.exitCode}`);
    const r = await fetch(`${BASE}/api/auth/providers`).catch(() => null);
    if (r?.ok) break;
    if (i > 120) throw new Error('wrangler dev did not answer within 60 s');
    await sleep(500);
  }
  ok(`wrangler dev answers on ${BASE}`);

  // ---- The Mac app's requests (AccountClient.send): JSON in and out, Bearer token when signed in.
  const app = async (method, path, { token, json } = {}) => {
    const headers = { accept: 'application/json' };
    if (token) headers.authorization = `Bearer ${token}`;
    if (json) headers['content-type'] = 'application/json';
    const r = await fetch(BASE + path, { method, headers, body: json && JSON.stringify(json) });
    const text = await r.text();
    let body;
    try {
      body = JSON.parse(text);
    } catch {
      body = text;
    }
    return { status: r.status, body };
  };

  // ---- 1. Device start.
  const start = await app('POST', '/api/device/start', { json: {} });
  assert.equal(start.status, 200, JSON.stringify(start.body));
  const { device_code, user_code, verification_uri_complete, expires_in, interval } = start.body;
  assert.ok(typeof device_code === 'string' && device_code.length >= 32, 'device_code is a long random string');
  assert.ok(typeof user_code === 'string' && user_code.length > 0, 'user_code');
  assert.equal(verification_uri_complete, `${BASE}/device?code=${user_code}`, 'verification_uri_complete is <AUTH_URL>/device?code=USER_CODE');
  assert.ok(Number.isInteger(expires_in) && expires_in > 0, 'expires_in');
  assert.ok(Number.isInteger(interval) && interval >= 1, 'interval');
  ok(`device/start: user_code ${user_code}, interval ${interval} s, expires_in ${expires_in} s`);

  // ---- 2. Before approval: pending, and a poll faster than `interval` is slow_down (RFC 8628).
  let poll = await app('POST', '/api/device/token', { json: { device_code } });
  assert.deepEqual([poll.status, poll.body.error], [400, 'authorization_pending']);
  poll = await app('POST', '/api/device/token', { json: { device_code } });
  assert.deepEqual([poll.status, poll.body.error], [400, 'slow_down']);
  ok('device/token before approval: 400 authorization_pending, then 400 slow_down when polled too fast');

  // ---- 3. The browser opens verification_uri_complete signed out and presses "Sign in with Google".
  // The button is a server-action form: post its fields as a browser without JS would.
  const page = await fetch(verification_uri_complete, { redirect: 'manual' });
  assert.equal(page.status, 200, `/device signed out: ${page.status}`);
  const form = [...(await page.text()).matchAll(/<form[^>]*>([\s\S]*?)<\/form>/g)].find((m) => /sign in/i.test(m[1]))?.[1];
  assert.ok(form, '/device signed out shows a sign-in form');
  const unescape = (s) => s.replace(/&quot;/g, '"').replace(/&#x27;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
  const fields = new FormData();
  for (const [, attrs] of form.matchAll(/<input([^>]*)>/g)) {
    const name = attrs.match(/name="([^"]*)"/)?.[1];
    if (name) fields.append(unescape(name), unescape(attrs.match(/value="([^"]*)"/)?.[1] ?? ''));
  }
  const signin = await fetch(verification_uri_complete, { method: 'POST', redirect: 'manual', headers: { origin: BASE }, body: fields });
  const google = new URL(signin.headers.get('location') ?? 'about:blank');
  assert.equal(google.origin, 'https://accounts.google.com', `sign-in redirects to Google, got ${signin.status} ${google}`);
  assert.equal(google.searchParams.get('redirect_uri'), `${BASE}/api/auth/callback/google`);
  const back = signin.headers.getSetCookie().find((c) => c.startsWith('authjs.callback-url='));
  assert.equal(decodeURIComponent(back?.split(';')[0].split('=')[1] ?? ''), verification_uri_complete, 'after Google, next-auth returns to /device?code=');
  ok('/device signed out: "Sign in with Google" goes to Google with redirect_uri <AUTH_URL>/api/auth/callback/google and comes back to /device?code=');

  // ---- 4. Fake the Google sign-in: a next-auth JWT session cookie, as the callback would set it.
  const email = `e2e-${randomBytes(4).toString('hex')}@example.com`;
  const cookieName = 'authjs.session-token'; // http: no __Secure- prefix
  const session = `${cookieName}=${await encode({ token: { email, name: 'E2E', sub: email }, secret: env.AUTH_SECRET, salt: cookieName })}`;
  const me = await (await fetch(`${BASE}/api/auth/session`, { headers: { cookie: session } })).json();
  assert.equal(me?.user?.email, email, 'the test session is accepted');
  const signedIn = await fetch(verification_uri_complete, { headers: { cookie: session }, redirect: 'manual' });
  assert.equal(signedIn.status, 200, `/device signed in: ${signedIn.status}`);
  assert.ok((await signedIn.text()).includes(user_code), '/device shows the code to confirm');
  ok(`test session for ${email}; /device shows ${user_code}`);

  // ---- 5. Approve, the way the /device page does.
  const approve = (headers, approve = true) =>
    fetch(`${BASE}/api/device/approve`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...headers },
      body: JSON.stringify({ user_code, approve }),
    });
  assert.equal((await approve({ origin: BASE })).status, 401, 'approve without a session');
  assert.equal((await approve({ origin: 'https://evil.example', cookie: session })).status, 403, 'approve cross-site');
  const approved = await approve({ origin: BASE, cookie: session });
  assert.equal(approved.status, 200, await approved.clone().text());
  assert.equal((await approve({ origin: BASE, cookie: session })).status, 404, 'a code is approved once');
  ok('device/approve: 401 signed out, 403 cross-site, 200 approved, 404 the second time');

  // ---- 6. Poll like DeviceFlow.signIn: sleep `interval`, slow_down adds 5 s, until granted or expired.
  let wait = interval;
  let grant;
  const deadline = Date.now() + expires_in * 1000;
  while (!grant) {
    await sleep(wait * 1000);
    assert.ok(Date.now() < deadline, 'the code expired while polling');
    poll = await app('POST', '/api/device/token', { json: { device_code } });
    if (poll.status === 200) grant = poll.body;
    else if (poll.status === 400 && poll.body.error === 'authorization_pending') continue;
    else if (poll.status === 400 && poll.body.error === 'slow_down') wait += 5;
    else assert.fail(`device/token: ${poll.status} ${JSON.stringify(poll.body)}`);
  }
  assert.ok(typeof grant.access_token === 'string' && grant.access_token.length >= 32, 'access_token');
  assert.equal(grant.email, email);
  await sleep(interval * 1000);
  poll = await app('POST', '/api/device/token', { json: { device_code } });
  assert.deepEqual([poll.status, poll.body.error], [400, 'expired_token'], 'a device code yields one token');
  ok('device/token: 200 {access_token, email} at the interval, then 400 expired_token');
  const token = grant.access_token;

  // ---- 7. License: trial for 30 days from the first sign-in.
  let lic = await app('GET', '/api/license', { token });
  assert.equal(lic.status, 200, JSON.stringify(lic.body));
  assert.equal(lic.body.status, 'trial');
  assert.equal(lic.body.email, email);
  const ends = Date.parse(lic.body.trial_ends_at);
  assert.ok(ends >= t0 + 30 * DAY && ends <= Date.now() + 30 * DAY, `trial_ends_at ${lic.body.trial_ends_at} is 30 days from the first sign-in`);
  assert.equal((await app('GET', '/api/license', { token: 'not-a-token' })).status, 401);
  assert.equal((await app('GET', '/api/license')).status, 401);
  ok(`license: trial until ${lic.body.trial_ends_at}; 401 for a bad or missing token`);

  // ---- 8. Checkout: a Stripe Checkout URL for the one-time price, tagged with the user id.
  assert.equal((await app('POST', '/api/checkout', { json: {} })).status, 401, 'checkout signed out');
  const co = await app('POST', '/api/checkout', { token, json: {} });
  assert.equal(co.status, 200, JSON.stringify(co.body));
  assert.match(co.body.url, /^https:\/\/checkout\.stripe\.com\//);
  assert.equal(stripeCalls.length, 1, 'one Stripe call');
  const sent = stripeCalls[0].params;
  assert.equal(stripeCalls[0].auth, `Bearer ${env.STRIPE_SECRET_KEY}`);
  assert.equal(sent.mode, 'payment');
  assert.equal(sent['line_items[0][price]'], env.STRIPE_PRICE_ID);
  assert.equal(sent['line_items[0][quantity]'], '1');
  assert.match(sent.client_reference_id ?? '', /^\d+$/, 'client_reference_id is the user id');
  ok(`checkout: ${co.body.url} (mode payment, ${env.STRIPE_PRICE_ID}, client_reference_id ${sent.client_reference_id})`);

  // ---- 9. Stripe's webhook. backant.io uses the same Stripe account, so this endpoint also gets
  // backant's checkouts: only a paid shepetal session may activate, everything else is a 200 no-op.
  const event = (type, session = {}) =>
    JSON.stringify({
      id: `evt_e2e_${randomBytes(6).toString('hex')}`,
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
          client_reference_id: sent.client_reference_id,
          customer_email: sent.customer_email ?? email,
          metadata: metadataOf(sent),
          ...session,
        },
      },
    });
  const hook = (body, secret = env.STRIPE_WEBHOOK_SECRET) => {
    const t = Math.floor(Date.now() / 1000);
    const v1 = createHmac('sha256', secret).update(`${t}.${body}`).digest('hex');
    return fetch(`${BASE}/api/stripe/webhook`, { method: 'POST', headers: { 'content-type': 'application/json', 'stripe-signature': `t=${t},v1=${v1}` }, body });
  };
  const stillTrial = async (why, body, status) => {
    const r = await hook(body, ...(status === 400 ? ['whsec_wrong'] : []));
    assert.equal(r.status, status, `${why}: ${await r.text()}`);
    assert.equal((await app('GET', '/api/license', { token })).body.status, 'trial', `${why} must not grant a license`);
  };
  await stillTrial('a bad signature', event('checkout.session.completed'), 400);
  // backant's own subscription checkout (backant-mcp web/src/app/api/checkout), paid, whose
  // client_reference_id happens to equal this shepetal user's id.
  await stillTrial(
    "backant's subscription checkout",
    event('checkout.session.completed', { mode: 'subscription', metadata: {}, subscription: 'sub_e2e', success_url: 'https://backant.io/dashboard/billing?success=1' }),
    200,
  );
  await stillTrial('an unpaid shepetal checkout (delayed payment method)', event('checkout.session.completed', { payment_status: 'unpaid' }), 200);
  const paid = await hook(event('checkout.session.completed'));
  assert.equal(paid.status, 200, await paid.clone().text());
  lic = await app('GET', '/api/license', { token });
  assert.deepEqual(lic.body, { status: 'active', trial_ends_at: null, email });
  ok("webhook: bad signature 400, backant's subscription checkout and an unpaid one 200 with no license; a paid shepetal checkout makes it active, trial_ends_at null");
}

let failed = false;
try {
  await main();
  console.log(`e2e: OK (${step} steps, ${Math.round((Date.now() - t0) / 1000)} s)`);
} catch (e) {
  failed = true;
  console.error(`not ok ${step + 1} - ${e.message}`);
  if (e.stack) console.error(e.stack.split('\n').slice(1, 4).join('\n'));
  try {
    const lines = readFileSync(logFile, 'utf8').trim().split('\n');
    console.error(`--- last lines of wrangler dev:\n${lines.slice(-40).join('\n')}`);
  } catch {}
} finally {
  teardown();
  await sleep(300);
  rmSync(tmp, { recursive: true, force: true });
}
process.exit(failed ? 1 : 0);
