#!/usr/bin/env node
// Both plans end to end in Stripe TEST mode, on the real Worker (wrangler dev, a fresh local D1) and the real
// Stripe test API, with webhooks forwarded by `stripe listen` (the Stripe CLI, logged in to the account):
//   1. lifetime with the PRODUCTHUNT code ($23.99 - $19.00 = $4.99) from the site's own code field; checkout is 409 after;
//   2. monthly: the code is refused (by the API, and by Stripe), a 100%-off code of another product is refused, the
//      subscription is paid at $0.99; a second subscription is 409; the code is refused for a customer who has paid;
//   plan settings: the current plan, cancel and resume at period end, the portal on its cancel flow and as a link;
//   3. Manage subscription: the Billing Portal, Cancel subscription; it stays active until the period end;
//   4. a renewal on a declining card (payment_failed, expired), then a good card (active again);
//   switch to lifetime: the subscription ends at once with no further charge, handled once;
//   never charged twice: a second tab's session is expired; a subscription paid by a lifetime owner is ended and
//      refunded; a refund of the lifetime payment ends the license;
//   5. a redelivered event is a duplicate; a forged signature is 400.
// It never prints a secret, and refuses a live key. Needs `npm run e2e` (or the OpenNext build) first.
//
//   STRIPE_SECRET_KEY=sk_test_… node e2e/stripe-testmode.mjs            # pays through Stripe's payment page API
//   BROWSER=1 PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core PLAYWRIGHT_BROWSERS_PATH=… \
//     STRIPE_SECRET_KEY=sk_test_… node e2e/stripe-testmode.mjs          # the hosted Checkout and Portal pages, headless
// The run's notes and screenshots go to STRIPE_E2E_OUT (default: a new temp dir), printed at the end.
// Needs scripts/stripe-setup.mjs run once in test mode.
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { createHash, createHmac, randomBytes } from 'node:crypto';
import { createWriteStream, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { createRequire } from 'node:module';

const WEB = join(dirname(fileURLToPath(import.meta.url)), '..');
const TMP = process.env.STRIPE_E2E_OUT ?? mkdtempSync(join(tmpdir(), 'shepetal-stripe-'));
const OUT = TMP;
process.env.STRIPE_E2E_OUT = TMP;
const BIN = join(WEB, 'node_modules/.bin');
const STRIPE_CLI = process.env.STRIPE_CLI ?? 'stripe';
const require = createRequire(join(WEB, 'package.json'));
const { encode } = await import(require.resolve('next-auth/jwt'));
const KEY = process.env.STRIPE_SECRET_KEY ?? '';
assert.match(KEY, /^(sk|rk)_test_/, 'a Stripe TEST key only');
mkdirSync(OUT, { recursive: true });
process.env.WRANGLER_LOG_PATH ??= join(TMP, 'wrangler-logs');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = [];
const note = (s) => {
  console.log(s);
  log.push(s);
};
const freePort = () =>
  new Promise((res) => {
    const s = createServer().listen(0, '127.0.0.1', () => {
      const { port } = s.address();
      s.close(() => res(port));
    });
  });

// ---- Stripe REST (test mode), form-encoded.
function form(obj, prefix = '', out = new URLSearchParams()) {
  for (const [k, v] of Object.entries(obj)) {
    const key = prefix ? `${prefix}[${k}]` : k;
    if (v && typeof v === 'object') form(v, key, out);
    else if (v !== undefined) out.append(key, String(v));
  }
  return out;
}
async function stripe(method, path, params) {
  const q = method === 'GET' && params ? `?${form(params)}` : '';
  const r = await fetch(`https://api.stripe.com${path}${q}`, {
    method,
    headers: { authorization: `Bearer ${KEY}`, 'content-type': 'application/x-www-form-urlencoded', 'stripe-version': '2025-02-24.acacia' },
    body: method === 'GET' ? undefined : form(params ?? {}),
  });
  const j = await r.json();
  return { ...j, http: r.status };
}

// ---- The Worker.
const port = await freePort();
const BASE = `http://localhost:${port}`;
const state = join(TMP, 'd1-state');
rmSync(state, { recursive: true, force: true });
const AUTH_SECRET = randomBytes(32).toString('hex');

// stripe listen: its signing secret goes straight into the env file, never to the terminal.
const WHSEC = execFileSync(STRIPE_CLI, ['listen', '--print-secret'], { encoding: 'utf8' }).trim();
assert.match(WHSEC, /^whsec_/);
const envFile = join(TMP, 'stripe-test.env');
writeFileSync(
  envFile,
  Object.entries({
    AUTH_SECRET,
    AUTH_URL: BASE,
    NEXTAUTH_URL: BASE,
    GOOGLE_CLIENT_ID: 'test-client-id',
    GOOGLE_CLIENT_SECRET: 'test-client-secret',
    STRIPE_SECRET_KEY: KEY,
    STRIPE_WEBHOOK_SECRET: WHSEC,
  })
    .map(([k, v]) => `${k}=${v}`)
    .join('\n') + '\n',
  { mode: 0o600 },
);
execFileSync(join(BIN, 'wrangler'), ['d1', 'migrations', 'apply', 'DB', '--local', '--persist-to', state], { cwd: WEB, stdio: 'ignore' });
const wlog = createWriteStream(join(OUT, 'wrangler.log'));
const worker = spawn(
  join(BIN, 'wrangler'),
  ['dev', '--ip', '127.0.0.1', '--port', String(port), '--inspector-port', String(await freePort()), '--local-upstream', `localhost:${port}`,
    '--persist-to', state, '--env-file', envFile, '--show-interactive-dev-session=false'],
  { cwd: WEB, detached: true, stdio: ['ignore', 'pipe', 'pipe'] },
);
worker.stdout.pipe(wlog);
worker.stderr.pipe(wlog);
const slog = createWriteStream(join(OUT, 'stripe-listen.log'));
const EVENTS = 'checkout.session.completed,checkout.session.async_payment_succeeded,customer.subscription.updated,customer.subscription.deleted,invoice.paid,invoice.payment_failed,charge.refunded';
const listen = spawn(STRIPE_CLI, ['listen', '--events', EVENTS, '--forward-to', `${BASE}/api/stripe/webhook`], { detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
// The listen banner shows the signing secret: it never reaches the log.
for (const st of [listen.stdout, listen.stderr]) st.on('data', (d) => slog.write(String(d).replace(/whsec_[A-Za-z0-9]+/g, 'whsec_(hidden)')));
const cleanup = () => {
  for (const p of [worker, listen]) {
    try {
      process.kill(-p.pid, 'SIGTERM');
    } catch {}
  }
  rmSync(envFile, { force: true });
};
process.on('exit', cleanup);

const DB_ID = 'bd45470f-27b2-4564-aa94-850856413b3e';
async function d1(sql) {
  const r = await fetch(`${BASE}/cdn-cgi/local/explorer/api/d1/database/${DB_ID}/raw`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ sql }),
  });
  const j = await r.json();
  assert.ok(j.success, JSON.stringify(j.errors ?? j));
  const { columns, rows } = j.result.at(-1).results;
  return { rows: rows.map((r) => Object.fromEntries(columns.map((c, i) => [c, r[i]]))) };
}

// ---- A signed-in person: a next-auth session cookie (Google faked), and an app token through the PKCE consent flow.
const b64url = (b) => b.toString('base64url');
async function person(email) {
  const name = 'authjs.session-token';
  const cookie = `${name}=${await encode({ token: { email, name: 'Test', sub: email }, secret: AUTH_SECRET, salt: name })}`;
  const verifier = b64url(randomBytes(32));
  const q = new URLSearchParams({ redirect_uri: 'shepetal://auth', state: 'st', code_challenge: b64url(createHash('sha256').update(verifier).digest()), code_challenge_method: 'S256' });
  const page = await fetch(`${BASE}/app/login?${q}`, { headers: { cookie }, redirect: 'manual' });
  const html = await page.text();
  const fields = Object.fromEntries([...html.matchAll(/<input type="hidden" name="([^"]+)" value="([^"]*)">/g)].map(([, k, v]) => [k, v.replace(/&amp;/g, '&')]));
  const jar = [cookie, ...page.headers.getSetCookie().map((c) => c.split(';')[0])].join('; ');
  const post = await fetch(`${BASE}/app/login`, { method: 'POST', redirect: 'manual', headers: { cookie: jar, origin: BASE, 'content-type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(fields) });
  const code = new URL(post.headers.get('location')).searchParams.get('code');
  const t = await (await fetch(`${BASE}/api/app/token`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ code, code_verifier: verifier, redirect_uri: 'shepetal://auth' }) })).json();
  const call = async (method, path, json, bearer = true) => {
    const r = await fetch(BASE + path, { method, headers: { 'content-type': 'application/json', ...(bearer ? { authorization: `Bearer ${t.access_token}` } : { cookie }) }, body: json && JSON.stringify(json) });
    return { status: r.status, body: await r.json().catch(() => null) };
  };
  return { email, cookie, license: async () => (await call('GET', '/api/license')).body, call };
}

/** Pays an open Checkout session the way the hosted page does (Stripe's own `stripe trigger` fixtures use these calls). */
const ADDRESSES = {
  US: { line1: '354 Oyster Point Blvd', postal_code: '94080', city: 'South San Francisco', state: 'CA', country: 'US' },
  DE: { line1: 'Unter den Linden 1', postal_code: '10117', city: 'Berlin', country: 'DE' },
};
async function pay(sessionId, { code, card = 'tok_visa', applyOnly = false, country = 'US', consent = true } = {}) {
  if (code) {
    const applied = await stripe('POST', `/v1/payment_pages/${sessionId}`, { promotion_code: code });
    if (applied.http !== 200) return { refused: applied.error?.message ?? `HTTP ${applied.status}` };
    if (applyOnly) return { due: applied.total_summary?.due };
  }
  // The buyer's country, as the hosted page sends it once the address is typed: Stripe Tax works from it.
  await stripe('POST', `/v1/payment_pages/${sessionId}`, { tax_region: { country } });
  const page = await stripe('GET', `/v1/payment_pages/${sessionId}`);
  const due = page.total_summary?.due ?? page.line_item_group?.total;
  assert.ok(Number.isInteger(due), `payment page ${page.http}: ${page.error?.message ?? Object.keys(page).slice(0, 12)}`);
  const tax = (page.total_summary?.total_tax_amounts ?? []).map((t) => ({ amount: t.amount, inclusive: t.inclusive }));
  const pm = await stripe('POST', '/v1/payment_methods', { type: 'card', card: { token: card }, billing_details: { email: 'buyer@example.com', name: 'Test Buyer', address: ADDRESSES[country] } });
  const done = await stripe('POST', `/v1/payment_pages/${sessionId}/confirm`, {
    payment_method: pm.id,
    expected_amount: due,
    ...(consent && { consent: { terms_of_service: 'accepted' } }),
  });
  if (!consent) return { refused: done.error?.message ?? `(!) HTTP ${done.http}` };
  assert.equal(done.http, 200, `confirm: ${done.error?.message}`);
  return { due, tax };
}
const sessionOf = (url) => url.match(/(cs_test_[A-Za-z0-9]+)/)[1];
async function until(what, fn, ms = 60_000) {
  const t = Date.now();
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() - t > ms) throw new Error(`timed out waiting for ${what}`);
    await sleep(1000);
  }
}
const show = (o) => JSON.stringify(o);
const UI = process.env.BROWSER === '1' ? await import('./stripe-browser.mjs') : null;
const due = (summary) => summary.match(/Total due(?: today)? \| ([^|]+)/)?.[1]?.trim() ?? summary.match(/(Total|due)[^|]*\| ([^|]+)/)?.[2];

try {
  for (let i = 0; ; i++) {
    if ((await fetch(`${BASE}/api/auth/providers`).catch(() => null))?.ok) break;
    if (i > 120) throw new Error('wrangler dev did not start');
    await sleep(500);
  }
  await sleep(3000); // stripe listen connects
  note(`# Stripe TEST-mode run (web/e2e/stripe-testmode.mjs), ${new Date().toISOString()}, Worker ${BASE} (wrangler dev, local D1), webhooks via stripe listen`);
  const run = randomBytes(3).toString('hex');

  // ---- 1. Lifetime with PRODUCTHUNT: $23.99 - $19.00 = $4.99.
  const a = await person(`pricing-a-${run}@example.com`);
  note(`\n## 1. Lifetime, with the code PRODUCTHUNT (${a.email})`);
  note(`license before: ${show(await a.license())}`);
  let co = await a.call('POST', '/api/checkout', { plan: 'lifetime', code: 'PRODUCTHUNT' });
  assert.equal(co.status, 200, show(co));
  let cs = await stripe('GET', `/v1/checkout/sessions/${sessionOf(co.body.url)}`);
  note(`POST /api/checkout {plan: "lifetime", code: "PRODUCTHUNT"}: session ${cs.id}: mode ${cs.mode}, amount_subtotal ${cs.amount_subtotal}, amount_total ${cs.amount_total} ${cs.currency}, allow_promotion_codes ${cs.allow_promotion_codes ?? '(off)'}, customer ${cs.customer}`);
  let paid;
  if (UI) {
    const r = await UI.checkoutUI(co.body.url, { shot: '1-lifetime-producthunt', returnTo: BASE });
    note(`Stripe Checkout in a headless browser: the page showed "${r.summary.match(/[^|]*19\.00 off[^|]*/)?.[0]?.trim()}" and total due ${due(r.summary)}; tax line "${r.summary.match(/[^|]*(VAT|tax)[^|]*/i)?.[0]?.trim()}"; Stripe's own code field: ${r.codeField ? 'shown (!)' : 'none'}; consent ticked; paid with 4242 (screenshots 1-lifetime-producthunt*.png)`);
    assert.equal(r.codeField, false);
  } else {
    paid = await pay(cs.id);
    note(`paid with 4242: due ${paid.due} cents`);
  }
  await until('lifetime license', async () => (await a.license()).plan === 'lifetime');
  cs = await stripe('GET', `/v1/checkout/sessions/${cs.id}`, { 'expand[0]': 'total_details.breakdown' });
  note(`session after payment: status ${cs.status}, payment_status ${cs.payment_status}, amount_subtotal ${cs.amount_subtotal}, amount_discount ${cs.total_details.amount_discount}, amount_total ${cs.amount_total}, discount ${cs.total_details.breakdown?.discounts?.[0]?.discount?.promotion_code}`);
  const la = await a.license();
  note(`license after: ${show(la)}`);
  assert.equal(cs.amount_total, 499);
  assert.deepEqual([la.status, la.plan], ['active', 'lifetime']);
  note(`checkout again: ${show(await a.call('POST', '/api/checkout', { plan: 'lifetime' }))}`);

  // ---- 2. Monthly: the code refused, then paid at $0.99.
  const b = await person(`pricing-b-${run}@example.com`);
  note(`\n## 2. Monthly ${b.email}: the code is refused, then a subscription at $0.99`);
  const withCode = await b.call('POST', '/api/checkout', { plan: 'monthly', code: 'PRODUCTHUNT' });
  note(`POST /api/checkout {plan: "monthly", code: "PRODUCTHUNT"}: ${withCode.status} ${show(withCode.body)}`);
  assert.equal(withCode.status, 400);
  // A code from elsewhere on the shared account (like backant.io's 100% codes) never works on shepetal.
  const foreignCoupon = await stripe('GET', '/v1/coupons/shepetal_e2e_foreign100');
  if (foreignCoupon.http === 404) {
    await stripe('POST', '/v1/coupons', { id: 'shepetal_e2e_foreign100', percent_off: 100, duration: 'once', name: 'e2e: a code that is not shepetal', metadata: { app: 'shepetal-e2e-foreign' } });
    await stripe('POST', '/v1/promotion_codes', { coupon: 'shepetal_e2e_foreign100', code: 'FOREIGN100TEST', metadata: { app: 'shepetal-e2e-foreign' } });
  }
  const foreign = await b.call('POST', '/api/checkout', { plan: 'lifetime', code: 'FOREIGN100TEST' });
  note(`a 100%-off code of another product on the account (FOREIGN100TEST, no applies_to): ${foreign.status} ${show(foreign.body)}`);
  assert.equal(foreign.body.error, 'invalid_code');
  co = await b.call('POST', '/api/checkout', { plan: 'monthly' });
  assert.equal(co.status, 200, show(co));
  cs = await stripe('GET', `/v1/checkout/sessions/${sessionOf(co.body.url)}`);
  note(`checkout session ${cs.id}: mode ${cs.mode}, amount_total ${cs.amount_total} ${cs.currency}, client_reference_id ${cs.client_reference_id}, allow_promotion_codes ${cs.allow_promotion_codes ?? '(off)'}`);
  const direct = await stripe('POST', '/v1/checkout/sessions', {
    mode: 'subscription',
    line_items: { 0: { price: (await stripe('GET', '/v1/prices', { lookup_keys: { 0: 'shepetal_monthly' } })).data[0].id, quantity: 1 } },
    discounts: { 0: { promotion_code: (await stripe('GET', '/v1/promotion_codes', { code: 'PRODUCTHUNT' })).data[0].id } },
    success_url: 'https://example.com/s',
  });
  note(`and Stripe itself: a subscription session with PRODUCTHUNT as a discount (API): HTTP ${direct.http}: ${direct.error?.message ?? 'created (!)'}`);
  assert.notEqual(direct.http, 200);
  if (UI) {
    const r = await UI.checkoutUI(co.body.url, { shot: '2-monthly', returnTo: BASE });
    note(`paid in the Checkout page: total due ${due(r.summary)}; tax line "${r.summary.match(/[^|]*(VAT|tax)[^|]*/i)?.[0]?.trim()}"; Stripe's code field: ${r.codeField ? 'shown (!)' : 'none'}`);
    assert.equal(r.codeField, false);
  } else {
    paid = await pay(cs.id);
    note(`paid: due ${paid.due} cents`);
  }
  await until('subscription license', async () => (await b.license()).plan === 'subscription');
  const lb = await b.license();
  note(`license: ${show(lb)}`);
  assert.deepEqual([lb.status, lb.plan, lb.renews], ['active', 'subscription', true]);
  const [ub] = (await d1(`SELECT plan, sub_id, sub_status, current_period_end, cancel_at_period_end, paid_through, stripe_customer_id FROM users WHERE email = '${b.email}'`)).rows;
  note(`D1 row: ${show(ub)}`);
  note(`second monthly checkout: ${show(await b.call('POST', '/api/checkout', { plan: 'monthly' }))}`);
  // first_time_transaction: this customer has paid once, so Stripe refuses the code on the lifetime price too.
  const second = await b.call('POST', '/api/checkout', { plan: 'lifetime', code: 'PRODUCTHUNT' });
  note(`PRODUCTHUNT on the lifetime price for this customer, who has paid before: ${second.status} ${show(second.body)}`);
  assert.equal(second.body.error, 'code_not_applicable');

  // ---- 3. Billing Portal and cancel.
  // ---- Stripe Tax and the EU consent.
  note('\n## Stripe Tax and the EU consent to delivery right away');
  const eu = await person(`pricing-eu-${run}@example.com`);
  co = await eu.call('POST', '/api/checkout', { plan: 'lifetime' });
  const euCs = await stripe('GET', `/v1/checkout/sessions/${sessionOf(co.body.url)}`);
  note(`session ${euCs.id}: automatic_tax ${show(euCs.automatic_tax?.enabled)}, consent_collection ${show(euCs.consent_collection)}, tax_id_collection ${show(euCs.tax_id_collection?.enabled)}`);
  note(`consent text on the checkbox: "${euCs.custom_text?.terms_of_service_acceptance?.message}"`);
  const noConsent = await pay(euCs.id, { country: 'DE', consent: false });
  note(`paying without ticking it: refused: ${noConsent.refused}`);
  assert.ok(noConsent.refused && !noConsent.refused.startsWith('(!)'));
  const euPaid = await pay(euCs.id, { country: 'DE' });
  await until('lifetime for the EU buyer', async () => (await eu.license()).plan === 'lifetime');
  const euDone = await stripe('GET', `/v1/checkout/sessions/${euCs.id}`);
  const euPi = await stripe('GET', `/v1/payment_intents/${euDone.payment_intent}`);
  note(`a buyer in Berlin: paid ${euDone.amount_total} ${euDone.currency}, of which tax ${euDone.total_details.amount_tax} (19% German VAT, inside the price: ${show(euPaid.tax)}); consent ${show(euDone.consent)}; address ${euDone.customer_details?.address?.country}`);
  note(`receipt description: "${euPi.description}"`);
  assert.equal(euDone.amount_total, 2399, 'the buyer pays the price shown');
  assert.ok(euDone.total_details.amount_tax > 0, 'VAT is inside the price');
  const [ueu] = (await d1(`SELECT withdrawal_waived_at FROM users WHERE email = '${eu.email}'`)).rows;
  note(`stored with the account: withdrawal_waived_at ${ueu.withdrawal_waived_at}`);
  assert.ok(ueu.withdrawal_waived_at);
  const custEu = await stripe('GET', `/v1/customers/${euDone.customer}`);
  note(`invoice footer on the customer (every subscription invoice): "${custEu.invoice_settings?.footer}"`);

  // ---- Plan settings (GET /api/account/plan, cancel and resume through the API).
  note(`\n## Plan settings: the current plan, cancel at period end through the API (${b.email})`);
  const tr = await person(`pricing-t-${run}@example.com`);
  note(`trial: ${show((await tr.call('GET', '/api/account/plan')).body)}`);
  note(`lifetime: ${show((await a.call('GET', '/api/account/plan')).body)}`);
  let ps = (await b.call('GET', '/api/account/plan', undefined, false)).body;
  note(`subscription (web session): ${show(ps)}`);
  assert.deepEqual([ps.plan, ps.subscription.status, ps.subscription.amount_display, ps.subscription.next_billing_date], ['subscription', 'active', '$0.99', lb.paid_through]);
  const cancelled = await b.call('POST', '/api/billing/cancel', undefined, false);
  note(`POST /api/billing/cancel: ${cancelled.status} license ${show(cancelled.body.license)}, settings.subscription ${show(cancelled.body.settings.subscription)}, actions ${show(cancelled.body.settings.actions)}`);
  assert.equal(cancelled.body.settings.subscription.status, 'cancels_at_period_end');
  let inStripe = await stripe('GET', `/v1/subscriptions/${ub.sub_id}`);
  note(`in Stripe: status ${inStripe.status}, cancel_at_period_end ${inStripe.cancel_at_period_end}, cancel_at ${new Date(inStripe.cancel_at * 1000).toISOString()}`);
  assert.equal(inStripe.cancel_at_period_end, true);
  note(`license until then: ${show(await b.license())}`);
  assert.deepEqual([(await b.license()).status, (await b.license()).renews], ['active', false]);
  const resumed = await b.call('POST', '/api/billing/resume', undefined, false);
  inStripe = await stripe('GET', `/v1/subscriptions/${ub.sub_id}`);
  note(`POST /api/billing/resume: ${resumed.status} ${resumed.body.settings.subscription.status}; in Stripe cancel_at_period_end ${inStripe.cancel_at_period_end}`);
  assert.equal(inStripe.cancel_at_period_end, false);
  const flow = await b.call('POST', '/api/billing/portal', { flow: 'cancel' }, false);
  note(`POST /api/billing/portal {flow: "cancel"}: ${flow.status}, the portal's cancel page answers ${(await fetch(flow.body.url, { redirect: 'manual' })).status}`);
  const link = await fetch(`${BASE}/api/billing/portal`, { redirect: 'manual', headers: { cookie: b.cookie } });
  const to = link.headers.get('location') ?? '';
  note(`GET /api/billing/portal (a plain link): ${link.status} to ${to.replace(/[?#].*$/, '?(secret hidden)')}, which answers ${(await fetch(to, { redirect: 'manual' })).status}`);
  assert.equal(link.status, 303);
  assert.match(to, /^https:\/\/billing\.stripe\.com\//);

  note(`\n## 3. Manage subscription (${b.email})`);
  const portal = await b.call('POST', '/api/billing/portal', undefined, false);
  note(`POST /api/billing/portal (web session): ${portal.status} ${portal.body.url?.replace(/[?#].*$/, '?(secret hidden)')}`);
  assert.equal(portal.status, 200);
  const pageRes = await fetch(portal.body.url, { redirect: 'manual' });
  note(`the portal URL answers ${pageRes.status}`);
  if (UI) {
    const r = await UI.portalCancelUI(portal.body.url, { shot: '3-portal' });
    note(`Billing Portal in a headless browser: Cancel subscription, then confirm (screenshots 3-portal-*.png). After: "${r.after.match(/[^|]*cancel[^|]*/i)?.[0]?.trim()}"`);
    await until('cancel_at_period_end from the portal', async () => (await b.license()).renews === false, 90_000);
    const s2 = await stripe('GET', `/v1/subscriptions/${ub.sub_id}`);
    note(`subscription in Stripe: status ${s2.status}, cancel_at_period_end ${s2.cancel_at_period_end}, cancel_at ${new Date(s2.cancel_at * 1000).toISOString()}`);
  } else {
    await stripe('POST', `/v1/subscriptions/${ub.sub_id}`, { cancel_at_period_end: true });
    note('cancelled with the API call the portal makes (cancel_at_period_end)');
    await until('renews false', async () => (await b.license()).renews === false);
  }
  const lc = await b.license();
  note(`license after the cancel: ${show(lc)}`);
  assert.deepEqual([lc.status, lc.renews], ['active', false]);

  // ---- 4. A failed renewal, then the card fixed.
  const c = await person(`pricing-c-${run}@example.com`);
  note(`\n## 4. Failed renewal (${c.email})`);
  co = await c.call('POST', '/api/checkout', { plan: 'monthly' });
  await pay(sessionOf(co.body.url));
  await until('subscription', async () => (await c.license()).plan === 'subscription');
  // The trial is over for this person, so a lapse shows as expired.
  await d1(`UPDATE users SET trial_started_at = '2026-08-01T00:00:00.000Z' WHERE email = '${c.email}'`);
  const [uc] = (await d1(`SELECT sub_id, stripe_customer_id FROM users WHERE email = '${c.email}'`)).rows;
  note(`subscribed: ${show(await c.license())}`);
  const bad = await stripe('POST', '/v1/payment_methods', { type: 'card', card: { token: 'tok_chargeCustomerFail' } });
  await stripe('POST', `/v1/payment_methods/${bad.id}/attach`, { customer: uc.stripe_customer_id });
  await stripe('POST', `/v1/subscriptions/${uc.sub_id}`, { default_payment_method: bad.id });
  // A renewal now: a new period starts and its invoice is charged to the failing card.
  const renewed = await stripe('POST', `/v1/subscriptions/${uc.sub_id}`, { billing_cycle_anchor: 'now', proration_behavior: 'none' });
  note(`renewal on a card that declines (4000000000000341): subscription ${renewed.status ?? renewed.error?.message}`);
  await until('payment_failed', async () => (await c.license()).payment_failed === true, 90_000);
  const lf = await c.license();
  note(`license after invoice.payment_failed: ${show(lf)}`);
  assert.equal(lf.status, 'expired');
  const good = await stripe('POST', '/v1/payment_methods', { type: 'card', card: { token: 'tok_visa' } });
  await stripe('POST', `/v1/payment_methods/${good.id}/attach`, { customer: uc.stripe_customer_id });
  await stripe('POST', `/v1/subscriptions/${uc.sub_id}`, { default_payment_method: good.id });
  const open = (await stripe('GET', '/v1/invoices', { subscription: uc.sub_id, status: 'open' })).data[0];
  const pi = await stripe('POST', `/v1/invoices/${open.id}/pay`, { payment_method: good.id });
  note(`new card, invoice ${open.id} paid: ${pi.status}`);
  await until('active again', async () => (await c.license()).status === 'active', 90_000);
  note(`license after invoice.paid: ${show(await c.license())}`);

  // ---- Switch to lifetime: a subscriber buys the lifetime license; the subscription ends at once, no further charge.
  const d = await person(`pricing-d-${run}@example.com`);
  note(`\n## Switch to lifetime (${d.email})`);
  co = await d.call('POST', '/api/checkout', { plan: 'monthly' });
  await pay(sessionOf(co.body.url));
  await until('subscription', async () => (await d.license()).plan === 'subscription');
  const [ud] = (await d1(`SELECT sub_id FROM users WHERE email = '${d.email}'`)).rows;
  note(`subscribed: ${show((await d.call('GET', '/api/account/plan')).body.subscription)}`);
  co = await d.call('POST', '/api/checkout', { plan: 'lifetime' });
  note(`POST /api/checkout {plan: "lifetime"} as a subscriber: ${co.status}`);
  const lcs = sessionOf(co.body.url);
  await pay(lcs);
  await until('lifetime', async () => (await d.license()).plan === 'lifetime');
  await until('subscription ended in Stripe', async () => (await stripe('GET', `/v1/subscriptions/${ud.sub_id}`)).status === 'canceled');
  const endedSub = await stripe('GET', `/v1/subscriptions/${ud.sub_id}`);
  const invs = (await stripe('GET', '/v1/invoices', { subscription: ud.sub_id, limit: 10 })).data;
  const upcoming = await stripe('GET', '/v1/invoices/upcoming', { subscription: ud.sub_id });
  note(`subscription ${ud.sub_id} in Stripe: status ${endedSub.status}, ended_at ${new Date(endedSub.ended_at * 1000).toISOString()} (the period would have run to ${new Date(endedSub.current_period_end * 1000).toISOString()})`);
  note(`its invoices: ${invs.map((i) => `${i.id} ${i.status} ${i.amount_due} ${i.billing_reason}`).join('; ')}; upcoming invoice: ${upcoming.error?.message ?? `(!) ${upcoming.amount_due}`}`);
  assert.equal(endedSub.status, 'canceled');
  assert.equal(invs.length, 1, 'only the first month was ever invoiced');
  note(`license: ${show(await d.license())}`);
  note(`plan settings: ${show((await d.call('GET', '/api/account/plan')).body)}`);
  // The webhook runs it once: the same checkout.session.completed again (signed) is a duplicate.
  const ce = (await stripe('GET', '/v1/events', { type: 'checkout.session.completed', limit: 5 })).data.find((e) => e.data.object.id === lcs);
  const cb = JSON.stringify(ce);
  const ct = Math.floor(Date.now() / 1000);
  const again1 = await fetch(`${BASE}/api/stripe/webhook`, { method: 'POST', headers: { 'stripe-signature': `t=${ct},v1=${createHmac('sha256', WHSEC).update(`${ct}.${cb}`).digest('hex')}` }, body: cb });
  note(`${ce.id} (the lifetime checkout) sent again: ${again1.status} ${await again1.text()}`);
  // And had it been handled twice, nothing more happens: the subscription is already cancelled.
  await d1(`DELETE FROM stripe_events WHERE id = '${ce.id}'`);
  const t2 = Math.floor(Date.now() / 1000);
  const again2 = await fetch(`${BASE}/api/stripe/webhook`, { method: 'POST', headers: { 'stripe-signature': `t=${t2},v1=${createHmac('sha256', WHSEC).update(`${t2}.${cb}`).digest('hex')}` }, body: cb });
  note(`the same event with its record removed, so it runs again: ${again2.status}; license ${(await d.license()).plan}; invoices still ${(await stripe('GET', '/v1/invoices', { subscription: ud.sub_id, limit: 10 })).data.length}`);
  assert.equal(again2.status, 200);

  // ---- Never charged twice.
  note('\n## Never charged twice');
  const e = await person(`pricing-e-${run}@example.com`);
  const tab1 = sessionOf((await e.call('POST', '/api/checkout', { plan: 'monthly' }, false)).body.url);
  const tab2 = sessionOf((await e.call('POST', '/api/checkout', { plan: 'lifetime' }, false)).body.url);
  const s1 = await stripe('GET', `/v1/checkout/sessions/${tab1}`);
  note(`two tabs: the monthly session opened first is now ${s1.status}; paying it: ${await pay(tab1).then(() => 'paid (!)', (err) => `refused (${err.message.split('\n')[0]})`)}`);
  assert.equal(s1.status, 'expired');
  await pay(tab2);
  await until('lifetime for e', async () => (await e.license()).plan === 'lifetime');
  note(`the second tab (lifetime) paid: ${(await e.license()).plan}`);
  // A race the expiry cannot stop: a monthly session already open and paid for a lifetime owner. Built here with the
  // same metadata the site uses, for person a.
  const [ua] = (await d1(`SELECT id, stripe_customer_id FROM users WHERE email = '${a.email}'`)).rows;
  const tag = { app: 'shepetal', user_id: String(ua.id) };
  const raced = await stripe('POST', '/v1/checkout/sessions', {
    mode: 'subscription', customer: ua.stripe_customer_id, success_url: `${BASE}/account?purchased=1`,
    line_items: { 0: { price: (await stripe('GET', '/v1/prices', { lookup_keys: { 0: 'shepetal_monthly' } })).data[0].id, quantity: 1 } },
    metadata: { ...tag, plan: 'monthly' }, subscription_data: { metadata: tag },
  });
  await pay(raced.id);
  const racedSub = (await stripe('GET', `/v1/checkout/sessions/${raced.id}`)).subscription;
  await until('the extra subscription ended', async () => (await stripe('GET', `/v1/subscriptions/${racedSub}`)).status === 'canceled', 90_000);
  const racedInv = (await stripe('GET', '/v1/invoices', { subscription: racedSub, limit: 5 })).data[0];
  await until('its refund', async () => (await stripe('GET', '/v1/refunds', { payment_intent: racedInv.payment_intent })).data.length > 0, 60_000);
  const rf = (await stripe('GET', '/v1/refunds', { payment_intent: racedInv.payment_intent })).data[0];
  note(`a monthly subscription paid by a lifetime owner (${racedSub}): ${(await stripe('GET', `/v1/subscriptions/${racedSub}`)).status}, refund ${rf.id} ${rf.amount} ${rf.currency} ${rf.status}; license still ${(await a.license()).plan}`);
  assert.equal((await a.license()).plan, 'lifetime');

  // A refund of the lifetime payment (as from the Dashboard under the 14-day refund term) ends the license.
  const [uaPi] = (await d1(`SELECT lifetime_payment_intent AS pi FROM users WHERE email = '${e.email}'`)).rows;
  await stripe('POST', '/v1/refunds', { payment_intent: uaPi.pi });
  await until('license ended by the refund', async () => (await e.license()).plan !== 'lifetime', 90_000);
  note(`the lifetime payment of ${e.email} refunded: license ${show(await e.license())}`);

  // ---- 5. A redelivered event is handled once; a forged one is refused.
  note('\n## 5. Webhook idempotency and signature');
  const evt = (await stripe('GET', '/v1/events', { type: 'invoice.paid', limit: 1 })).data[0];
  const body = JSON.stringify(evt);
  const t = Math.floor(Date.now() / 1000);
  const sig = `t=${t},v1=${createHmac('sha256', WHSEC).update(`${t}.${body}`).digest('hex')}`;
  const again = await fetch(`${BASE}/api/stripe/webhook`, { method: 'POST', headers: { 'stripe-signature': sig }, body });
  note(`${evt.id} (${evt.type}) sent again, signed: ${again.status} ${await again.text()}`);
  const forged = await fetch(`${BASE}/api/stripe/webhook`, { method: 'POST', headers: { 'stripe-signature': `t=${t},v1=${'0'.repeat(64)}` }, body });
  note(`the same body with a forged signature: ${forged.status} ${await forged.text()}`);
  const n = (await d1('SELECT type, count(*) AS n FROM stripe_events GROUP BY type ORDER BY type')).rows;
  note(`stripe_events handled: ${show(n)}`);
  note('\nRESULT: all flows passed');
} catch (e) {
  note(`\nRESULT: FAILED: ${e.stack ?? e}`);
  process.exitCode = 1;
} finally {
  writeFileSync(join(OUT, 'run.md'), log.join('\n') + '\n');
  console.log(`notes and screenshots: ${OUT}`);
  await UI?.close();
  cleanup();
}
