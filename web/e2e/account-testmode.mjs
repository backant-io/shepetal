#!/usr/bin/env node
// The plan settings on /account, end to end in Stripe TEST mode, the way a person uses them in a browser:
//   1. a trial user picks the $0.99 plan (Subscribe) on /account and pays on Stripe's hosted Checkout (card 4242);
//   2. /account shows Monthly, Active, the next charge ($0.99 and its date), Manage billing, Switch to lifetime, Cancel;
//   3. Manage billing opens the Stripe Billing Portal for this customer;
//   4. Cancel subscription, the confirmation, Cancel subscription: Stripe has cancel_at_period_end, the license stays
//      active until the period end, /account says it cancels at the end of the period; Resume undoes it;
//   5. Switch to lifetime: Stripe Checkout for $23.99 (card 4242); /account says "Yours forever." with no subscription
//      controls; in Stripe the subscription is cancelled, with no further invoice.
// Real Worker (wrangler dev, a fresh local D1), the real Stripe test API, webhooks through `stripe listen`, and the
// pages in chromium headless shell (no window, no focus, no clipboard). It never prints a secret and refuses a live key.
// Needs the OpenNext build (npm run e2e builds it) and scripts/stripe-setup.mjs run once in test mode.
//
//   PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core PLAYWRIGHT_BROWSERS_PATH=… STRIPE_SECRET_KEY=sk_test_… \
//     ACCOUNT_E2E_OUT=/path/for/notes-and-screenshots node e2e/account-testmode.mjs
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { createWriteStream, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const WEB = join(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = process.env.ACCOUNT_E2E_OUT ?? mkdtempSync(join(tmpdir(), 'shepetal-account-'));
mkdirSync(OUT, { recursive: true });
const BIN = join(WEB, 'node_modules/.bin');
const STRIPE_CLI = process.env.STRIPE_CLI ?? 'stripe';
const require = createRequire(join(WEB, 'package.json'));
const { encode } = await import(require.resolve('next-auth/jwt'));
const { chromium } = await import(process.env.PLAYWRIGHT_CORE ? join(process.env.PLAYWRIGHT_CORE, 'index.mjs') : 'playwright-core');
const KEY = process.env.STRIPE_SECRET_KEY ?? '';
assert.match(KEY, /^(sk|rk)_test_/, 'a Stripe TEST key only');
process.env.WRANGLER_LOG_PATH ??= join(OUT, 'wrangler-logs');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const lines = [];
const note = (s) => {
  console.log(s);
  lines.push(s);
};
const freePort = () =>
  new Promise((res) => {
    const s = createServer().listen(0, '127.0.0.1', () => {
      const { port } = s.address();
      s.close(() => res(port));
    });
  });

async function stripe(method, path) {
  const r = await fetch(`https://api.stripe.com${path}`, {
    method,
    headers: { authorization: `Bearer ${KEY}`, 'stripe-version': '2025-02-24.acacia' },
  });
  return r.json();
}

// ---- The Worker and the webhook forwarder.
const port = await freePort();
const BASE = `http://localhost:${port}`;
const state = join(OUT, 'd1-state');
rmSync(state, { recursive: true, force: true });
const AUTH_SECRET = randomBytes(32).toString('hex');
const WHSEC = execFileSync(STRIPE_CLI, ['listen', '--print-secret'], { encoding: 'utf8' }).trim();
assert.match(WHSEC, /^whsec_/);
const envFile = join(OUT, 'account-test.env');
const vars = {
  AUTH_SECRET,
  AUTH_URL: BASE,
  NEXTAUTH_URL: BASE,
  GOOGLE_CLIENT_ID: 'test-client-id',
  GOOGLE_CLIENT_SECRET: 'test-client-secret',
  STRIPE_SECRET_KEY: KEY,
  STRIPE_WEBHOOK_SECRET: WHSEC,
};
writeFileSync(envFile, Object.entries(vars).map(([k, v]) => `${k}=${v}`).join('\n') + '\n', { mode: 0o600 });
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
const EVENTS = 'checkout.session.completed,checkout.session.async_payment_succeeded,customer.subscription.updated,customer.subscription.deleted,invoice.paid,invoice.payment_failed';
const listen = spawn(STRIPE_CLI, ['listen', '--events', EVENTS, '--forward-to', `${BASE}/api/stripe/webhook`], { detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
for (const st of [listen.stdout, listen.stderr]) st.on('data', (d) => slog.write(String(d).replace(/whsec_[A-Za-z0-9]+/g, 'whsec_(hidden)')));
let browser;
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
async function user(email) {
  const r = await fetch(`${BASE}/cdn-cgi/local/explorer/api/d1/database/${DB_ID}/raw`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ sql: `SELECT * FROM users WHERE email = '${email}'` }),
  });
  const j = await r.json();
  const { columns, rows } = j.result.at(-1).results;
  return rows[0] && Object.fromEntries(columns.map((c, i) => [c, rows[0][i]]));
}
async function until(what, fn, ms = 90_000) {
  const t = Date.now();
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() - t > ms) throw new Error(`timed out waiting for ${what}`);
    await sleep(1000);
  }
}

// ---- The browser: the account page, as the signed-in person sees it.
const text = async (p) => (await p.locator('main').innerText()).replace(/\s*\n\s*/g, ' | ');
async function shot(p, name) {
  await p.screenshot({ path: join(OUT, `${name}-1440.png`), fullPage: true });
  const phone = await p.context().browser().newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  await phone.addCookies(await p.context().cookies());
  const q = await phone.newPage();
  await q.goto(p.url(), { waitUntil: 'networkidle' });
  await q.screenshot({ path: join(OUT, `${name}-390.png`), fullPage: true });
  await phone.close();
}
/** Stripe's hosted Checkout, as a buyer pays: US dollars, the test card 4242, Pay; back on /account. */
async function payOnCheckout(p, name) {
  await p.waitForURL(/checkout\.stripe\.com/, { timeout: 60_000 });
  await p.locator('button[type="submit"]').waitFor({ timeout: 60_000 });
  await p.waitForTimeout(1500);
  const usd = p.getByRole('button', { name: /^(USD|\$)/ }).first();
  if (await usd.count()) await usd.click().catch(() => {});
  const summary = (await p.locator('body').innerText()).replace(/\s*\n\s*/g, ' | ');
  const card = p.locator('input[type="radio"][value="card"], #payment-method-accordion-item-title-card');
  if (await card.count()) await card.first().check({ force: true }).catch(() => card.first().click({ force: true }));
  await p.locator('#cardNumber').waitFor({ timeout: 15_000 });
  await p.locator('#cardNumber').fill('4242 4242 4242 4242');
  await p.locator('#cardExpiry').fill('12 / 34');
  await p.locator('#cardCvc').fill('123');
  await p.locator('#billingName').fill('Test Buyer').catch(() => {});
  if (await p.locator('#billingCountry').count()) await p.locator('#billingCountry').selectOption('US').catch(() => {});
  if (await p.locator('#billingPostalCode').count()) await p.locator('#billingPostalCode').fill('94103').catch(() => {});
  await p.screenshot({ path: join(OUT, `${name}-checkout.png`), fullPage: true });
  await p.locator('button[type="submit"]').click();
  await p.waitForURL((u) => u.href.startsWith(`${BASE}/account`), { timeout: 90_000 });
  return summary;
}

let failed = false;
try {
  for (let i = 0; ; i++) {
    if ((await fetch(`${BASE}/api/auth/providers`).catch(() => null))?.ok) break;
    if (i > 120) throw new Error('wrangler dev did not start');
    await sleep(500);
  }
  await sleep(3000); // stripe listen connects
  note(`# /account plan settings in Stripe TEST mode (web/e2e/account-testmode.mjs), ${new Date().toISOString()}`);
  note(`Worker ${BASE} (wrangler dev, local D1); webhooks via stripe listen; pages in chromium headless shell.`);
  const email = `settings-${randomBytes(3).toString('hex')}@example.com`;
  const name = 'authjs.session-token';
  const value = await encode({ token: { email, name: 'Test', sub: email }, secret: AUTH_SECRET, salt: name });
  browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, locale: 'en-US' });
  await ctx.addCookies([{ name, value, url: BASE }]);
  const p = await ctx.newPage();
  p.on('dialog', (d) => d.dismiss());

  // ---- 0. The trial: days left, the download, the two plans.
  await p.goto(`${BASE}/account`, { waitUntil: 'networkidle' });
  let t = await text(p);
  note(`\n## 0. Trial (${email})\n/account: ${t}`);
  assert.match(t, /30 days left\./);
  assert.match(t, /\$23\.99 \| once\. Yours forever\./);
  assert.match(t, /\$0\.99 \| a month\./);
  await shot(p, '0-trial');

  // ---- 1. Subscribe from the plans on /account.
  await p.getByRole('button', { name: 'Subscribe' }).click();
  const sumMonthly = await payOnCheckout(p, '1-subscribe');
  note(`\n## 1. Subscribe ($0.99 a month) from /account\nStripe Checkout said: ${sumMonthly.slice(0, 240)}…\nPaid with 4242, back on ${new URL(p.url()).pathname}${new URL(p.url()).search}`);
  const u1 = await until('the subscription webhook', async () => {
    const u = await user(email);
    return u?.sub_status === 'active' && u.sub_amount ? u : null;
  });
  note(`D1 after the webhook: plan ${u1.plan}, sub_status ${u1.sub_status}, paid_through ${u1.paid_through}, amount ${u1.sub_amount} ${u1.sub_currency}`);
  await p.goto(`${BASE}/account?purchased=1`, { waitUntil: 'networkidle' });
  t = await text(p);
  note(`/account: ${t}`);
  for (const s of ['Your subscription is on. Thank you.', 'Monthly', 'Active', 'Next charge', '$0.99', 'Manage billing', 'Switch to lifetime', 'Cancel subscription'])
    assert.ok(t.includes(s), `subscriber settings show ${s}`);
  await shot(p, '1-subscribed');

  // ---- 2. Manage billing: the Stripe Billing Portal for this customer.
  const portal = await p.context().newPage();
  await portal.goto(`${BASE}/api/billing/portal`, { waitUntil: 'load', timeout: 60_000 });
  await portal.waitForURL(/billing\.stripe\.com/, { timeout: 60_000 });
  await portal.waitForTimeout(3000);
  const portalText = (await portal.locator('body').innerText()).replace(/\s*\n\s*/g, ' | ');
  await portal.screenshot({ path: join(OUT, '2-manage-billing-portal.png'), fullPage: true });
  note(`\n## 2. Manage billing\nOpened ${new URL(portal.url()).origin}/p/session/… : ${portalText.slice(0, 300)}…`);
  assert.match(portalText, /\$0\.99/);
  await portal.close();

  // ---- 3. Cancel subscription, with the confirmation; it cancels at period end. Then Resume, and cancel again.
  await p.getByRole('button', { name: 'Cancel subscription' }).click();
  const dialog = p.getByRole('dialog');
  await dialog.waitFor();
  const confirmText = (await dialog.innerText()).replace(/\s*\n\s*/g, ' | ');
  await p.screenshot({ path: join(OUT, '3-cancel-confirm-1440.png') });
  note(`\n## 3. Cancel subscription\nThe confirmation: ${confirmText}`);
  await dialog.getByRole('button', { name: 'Cancel subscription' }).click();
  await p.waitForLoadState('networkidle');
  await p.waitForTimeout(1500);
  t = await text(p);
  note(`/account after: ${t}`);
  assert.ok(t.includes('Cancels at the end of the period') && t.includes('Resume subscription'), 'cancelled at period end');
  const s1 = await stripe('GET', `/v1/subscriptions/${u1.sub_id}`);
  note(`Stripe: subscription ${s1.id} status ${s1.status}, cancel_at_period_end ${s1.cancel_at_period_end}, current_period_end ${new Date((s1.current_period_end ?? s1.items?.data?.[0]?.current_period_end) * 1000).toISOString()}`);
  assert.equal(s1.cancel_at_period_end, true);
  assert.equal(s1.status, 'active');
  const lic1 = await (await fetch(`${BASE}/api/account/plan`, { headers: { cookie: `${name}=${value}` } })).json();
  note(`GET /api/account/plan: status ${lic1.status}, subscription ${JSON.stringify(lic1.subscription)}`);
  assert.equal(lic1.status, 'active', 'the license works until the period ends');
  await shot(p, '3-cancelled');
  await p.getByRole('button', { name: 'Resume subscription' }).click();
  await until('the resume', async () => (await text(p)).includes('Renews on'), 30_000);
  const s2 = await stripe('GET', `/v1/subscriptions/${u1.sub_id}`);
  note(`Resume subscription: Stripe cancel_at_period_end ${s2.cancel_at_period_end}; /account: ${(await text(p)).slice(0, 200)}…`);
  assert.equal(s2.cancel_at_period_end, false);

  // ---- 4. Switch to lifetime: $23.99 once; the subscription ends with no further charge.
  await p.getByRole('button', { name: 'Switch to lifetime' }).click();
  const sumLifetime = await payOnCheckout(p, '4-switch');
  note(`\n## 4. Switch to lifetime\nStripe Checkout said: ${sumLifetime.slice(0, 240)}…\nPaid with 4242, back on ${new URL(p.url()).pathname}${new URL(p.url()).search}`);
  const u2 = await until('the lifetime webhook', async () => {
    const u = await user(email);
    return u?.plan === 'lifetime' && u.sub_status === 'canceled' ? u : null;
  });
  note(`D1 after the webhook: plan ${u2.plan}, status ${u2.status}, sub_status ${u2.sub_status}`);
  const s3 = await stripe('GET', `/v1/subscriptions/${u1.sub_id}`);
  const invoices = await stripe('GET', `/v1/invoices?subscription=${u1.sub_id}&limit=10`);
  note(`Stripe: subscription status ${s3.status}, ended_at ${s3.ended_at && new Date(s3.ended_at * 1000).toISOString()}; its invoices: ${invoices.data.map((i) => `${i.billing_reason} ${i.status} ${i.amount_due}`).join(', ')}`);
  assert.equal(s3.status, 'canceled');
  assert.ok(invoices.data.every((i) => i.billing_reason === 'subscription_create'), 'no invoice after the first one');
  await p.goto(`${BASE}/account?purchased=1`, { waitUntil: 'networkidle' });
  t = await text(p);
  note(`/account: ${t}`);
  assert.ok(t.includes('Yours forever.') && t.includes('Lifetime'));
  for (const s of ['Cancel subscription', 'Switch to lifetime', 'Manage billing', 'Next charge']) assert.ok(!t.includes(s), `no ${s} for lifetime`);
  await shot(p, '4-lifetime');
  note('\nAll steps passed.');
} catch (e) {
  failed = true;
  note(`\nFAILED: ${e.stack ?? e}`);
} finally {
  await browser?.close();
  writeFileSync(join(OUT, 'account-testmode.log'), lines.join('\n') + '\n');
  console.log(`notes and screenshots: ${OUT}`);
  cleanup();
  process.exit(failed ? 1 : 0);
}
