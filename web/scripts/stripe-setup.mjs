#!/usr/bin/env node
// Creates, or finds, shepetal's Stripe objects and prints their IDs. Safe to run again: it changes
// nothing that is already as wanted.
//
//   STRIPE_SECRET_KEY=sk_test_… node scripts/stripe-setup.mjs          # test mode
//   STRIPE_SECRET_KEY=sk_live_… node scripts/stripe-setup.mjs --live   # live mode, only with --live
//
// What it sets up (each found by its lookup_key, its id, or metadata app=shepetal; nothing else in the
// shared account is read for a decision or changed):
//   - product "Shepetal" (metadata app=shepetal, plan=lifetime, tax code downloadable software) with a one-time price,
//     lookup_key shepetal_lifetime.
//     A product with metadata app=shepetal and no plan (the first $4.99 product) becomes this product.
//   - product "Shepetal Monthly" (metadata app=shepetal, plan=monthly, tax code downloadable software) with a monthly price,
//     lookup_key shepetal_monthly.
//   - both prices tax-inclusive (Stripe Tax takes the VAT or sales tax out of the price, so the buyer pays the price
//     shown), in USD with a EUR price for EU buyers (currency_options). Set per price, so the account's default
//     (live: inferred_by_currency, which makes USD exclusive) never applies.
//   - coupon (id shepetal_producthunt_2): an amount off in USD and in EUR, once, applies_to the lifetime product only.
//   - promotion code PRODUCTHUNT for that coupon: first_time_transaction, an expiry date. An active PRODUCTHUNT of an
//     older shepetal coupon is deactivated first.
//   - a Billing Portal configuration (metadata app=shepetal): cancel at period end, update the card, invoices.
// The other active prices on the lifetime product (the old $4.99 one) are archived: past purchases keep working.
// Webhooks are left alone: the script prints the events the endpoint needs.
//
// Change the defaults with env vars:
//   LIFETIME_CENTS=2399 MONTHLY_CENTS=99 LIFETIME_EUR_CENTS=2399 MONTHLY_EUR_CENTS=99 TAX_BEHAVIOR=inclusive
//   PH_CODE=PRODUCTHUNT PH_CENTS_OFF=1900 PH_EUR_CENTS_OFF=1900 PH_EXPIRES=2026-11-01T00:00:00Z PH_COUPON_ID=shepetal_producthunt_2
// The site address (portal return and legal URLs) is https://<SHEPETAL_DOMAIN> from wrangler.toml.
// A coupon or promotion code cannot be edited in Stripe once made: to change PH_CENTS_OFF, give a new
// PH_COUPON_ID; to change the code's rules or expiry, archive the code in the Dashboard and run this again.
import { readFileSync } from 'node:fs';
import Stripe from 'stripe';

const live = process.argv.includes('--live');
const key = process.env.STRIPE_SECRET_KEY ?? '';
if (!/^(sk|rk)_(test|live)_/.test(key)) fail('STRIPE_SECRET_KEY must be a Stripe secret or restricted key');
const keyLive = /^(sk|rk)_live_/.test(key);
if (keyLive && !live) fail('this is a live key: pass --live to change the live account');
if (!keyLive && live) fail('--live was passed with a test key');

const domain = readFileSync(new URL('../wrangler.toml', import.meta.url), 'utf8').match(/^SHEPETAL_DOMAIN\s*=\s*"([^"]+)"/m)?.[1];
if (!domain) fail('wrangler.toml has no SHEPETAL_DOMAIN');
const cfg = {
  lifetimeCents: int('LIFETIME_CENTS', 2399),
  monthlyCents: int('MONTHLY_CENTS', 99),
  lifetimeEur: int('LIFETIME_EUR_CENTS', 2399),
  monthlyEur: int('MONTHLY_EUR_CENTS', 99),
  taxBehavior: process.env.TAX_BEHAVIOR ?? 'inclusive',
  code: process.env.PH_CODE ?? 'PRODUCTHUNT',
  centsOff: int('PH_CENTS_OFF', 1900),
  eurOff: int('PH_EUR_CENTS_OFF', 1900),
  expires: Math.floor(Date.parse(process.env.PH_EXPIRES ?? '2026-11-01T00:00:00Z') / 1000),
  couponId: process.env.PH_COUPON_ID ?? 'shepetal_producthunt_2',
  site: `https://${domain}`,
};
if (!['inclusive', 'exclusive'].includes(cfg.taxBehavior)) fail('TAX_BEHAVIOR must be inclusive or exclusive');
// Both products: Downloadable Software, personal use (the app is downloaded and runs on the Mac; buyers are consumers).
// Set per product, so the account's default (live: txcd_10103001, SaaS business use) never applies. As src/lib/stripe.ts.
const TAX_CODES = { lifetime: 'txcd_10202000', monthly: 'txcd_10202000' };
if (!Number.isFinite(cfg.expires)) fail('PH_EXPIRES is not a date');
if (cfg.centsOff >= cfg.lifetimeCents) fail('PH_CENTS_OFF must be less than LIFETIME_CENTS');

const APP = 'shepetal';
const stripe = new Stripe(key, { apiVersion: '2025-02-24.acacia' });
const out = { mode: keyLive ? 'live' : 'test' };
const notes = [];

function fail(msg) {
  console.error(`stripe-setup: ${msg}`);
  process.exit(1);
}
function int(name, dflt) {
  const v = process.env[name];
  if (v === undefined) return dflt;
  if (!/^\d+$/.test(v)) fail(`${name} must be a whole number of cents`);
  return Number(v);
}
const ours = (o) => o?.metadata?.app === APP;

async function shepetalProducts() {
  const all = [];
  for await (const p of stripe.products.list({ limit: 100 })) if (ours(p)) all.push(p);
  return all;
}

/** The product with metadata plan=`plan`; for lifetime, else the original product (app=shepetal, no plan). */
async function product(products, plan, name) {
  let p = products.find((x) => x.metadata.plan === plan && x.active) ?? products.find((x) => x.metadata.plan === plan);
  if (!p && plan === 'lifetime') p = products.find((x) => !x.metadata.plan);
  if (!p) {
    p = await stripe.products.create({ name, tax_code: TAX_CODES[plan], metadata: { app: APP, plan } });
    notes.push(`created product ${p.id} (${name}, tax code ${TAX_CODES[plan]})`);
  } else if (!p.active || p.metadata.plan !== plan || p.tax_code !== TAX_CODES[plan]) {
    p = await stripe.products.update(p.id, { active: true, tax_code: TAX_CODES[plan], metadata: { app: APP, plan } });
    notes.push(`updated product ${p.id}: active, metadata plan=${plan}, tax code ${TAX_CODES[plan]}`);
  }
  return p;
}

/** The active price with this lookup_key, matching the amount and interval; else a new one that takes the key over. */
async function price(lookup, productId, cents, eurCents, recurring) {
  const { data } = await stripe.prices.list({ lookup_keys: [lookup], limit: 1, expand: ['data.product', 'data.currency_options'] });
  const cur = data[0];
  const eur = cur?.currency_options?.eur;
  const same =
    cur &&
    cur.active &&
    (typeof cur.product === 'string' ? cur.product : cur.product.id) === productId &&
    cur.unit_amount === cents &&
    cur.currency === 'usd' &&
    cur.tax_behavior === cfg.taxBehavior &&
    eur?.unit_amount === eurCents &&
    eur?.tax_behavior === cfg.taxBehavior &&
    (recurring ? cur.recurring?.interval === 'month' && cur.recurring.interval_count === 1 : cur.type === 'one_time');
  if (same) return cur;
  if (cur && !ours(typeof cur.product === 'string' ? await stripe.products.retrieve(cur.product) : cur.product)) {
    fail(`lookup_key ${lookup} belongs to a price of another product (${cur.id}): not touching it`);
  }
  const p = await stripe.prices.create({
    product: productId,
    currency: 'usd',
    unit_amount: cents,
    tax_behavior: cfg.taxBehavior,
    currency_options: { eur: { unit_amount: eurCents, tax_behavior: cfg.taxBehavior } },
    ...(recurring && { recurring: { interval: 'month', interval_count: 1 } }),
    lookup_key: lookup,
    transfer_lookup_key: true,
    metadata: { app: APP },
  });
  notes.push(`created price ${p.id} (${lookup}, ${cents} USD cents and ${eurCents} EUR cents ${cfg.taxBehavior} of tax${recurring ? ' a month' : ' once'})${cur ? `, took the lookup_key from ${cur.id}` : ''}`);
  return p;
}

async function archiveOtherPrices(productId, keep) {
  for await (const p of stripe.prices.list({ product: productId, active: true, limit: 100 })) {
    if (p.id === keep) continue;
    await stripe.prices.update(p.id, { active: false });
    notes.push(`archived old price ${p.id} (${p.unit_amount} ${p.currency}) on ${productId}`);
  }
}

async function coupon(productId) {
  const want = { amount_off: cfg.centsOff, currency: 'usd', duration: 'once', currency_options: { eur: { amount_off: cfg.eurOff } } };
  let c = await stripe.coupons
    .retrieve(cfg.couponId, { expand: ['applies_to', 'currency_options'] })
    .catch((e) => (e.statusCode === 404 ? null : Promise.reject(e)));
  if (!c) {
    c = await stripe.coupons.create({
      id: cfg.couponId,
      name: 'Product Hunt',
      ...want,
      applies_to: { products: [productId] },
      metadata: { app: APP },
    });
    notes.push(`created coupon ${c.id}`);
    return stripe.coupons.retrieve(c.id, { expand: ['applies_to', 'currency_options'] });
  }
  if (!ours(c)) fail(`coupon ${c.id} exists without metadata app=shepetal: pick another PH_COUPON_ID`);
  const products = c.applies_to?.products ?? [];
  if (c.amount_off !== want.amount_off || c.currency !== 'usd' || c.duration !== 'once' || c.currency_options?.eur?.amount_off !== cfg.eurOff ||
      products.length !== 1 || products[0] !== productId) {
    fail(`coupon ${c.id} differs from the wanted one (${cfg.centsOff} USD and ${cfg.eurOff} EUR cents off once, lifetime product only). Coupons cannot be edited: set a new PH_COUPON_ID`);
  }
  if (!c.valid) fail(`coupon ${c.id} is no longer valid: set a new PH_COUPON_ID`);
  return c;
}

async function promotionCode(couponId) {
  const { data } = await stripe.promotionCodes.list({ code: cfg.code, active: true, limit: 10 });
  const mine = data.find((p) => p.coupon.id === couponId);
  if (mine) {
    const r = mine.restrictions;
    if (!r.first_time_transaction || mine.expires_at !== cfg.expires || mine.max_redemptions !== null || r.minimum_amount) {
      fail(`promotion code ${cfg.code} (${mine.id}) has other rules or another expiry. Archive it in the Dashboard, then run this again`);
    }
    return mine;
  }
  for (const other of data) {
    // A code is unique among active codes: an older shepetal coupon's PRODUCTHUNT steps aside; anyone else's stays.
    if (other.coupon.metadata?.app !== APP) fail(`an active promotion code ${cfg.code} exists for another product's coupon (${other.id}): not touching it`);
    await stripe.promotionCodes.update(other.id, { active: false });
    notes.push(`deactivated ${cfg.code} ${other.id} of the older coupon ${other.coupon.id}`);
  }
  const p = await stripe.promotionCodes.create({
    coupon: couponId,
    code: cfg.code,
    expires_at: cfg.expires,
    restrictions: { first_time_transaction: true },
    metadata: { app: APP },
  });
  notes.push(`created promotion code ${p.code} (${p.id})`);
  return p;
}

async function portal() {
  const want = {
    business_profile: { headline: 'shepetal', privacy_policy_url: `${cfg.site}/privacy`, terms_of_service_url: `${cfg.site}/terms` },
    default_return_url: `${cfg.site}/account`,
    features: {
      customer_update: { enabled: false },
      invoice_history: { enabled: true },
      payment_method_update: { enabled: true },
      subscription_cancel: { enabled: true, mode: 'at_period_end', proration_behavior: 'none' },
      subscription_update: { enabled: false },
    },
    metadata: { app: APP },
  };
  for await (const c of stripe.billingPortal.configurations.list({ limit: 100 })) {
    if (!ours(c)) continue;
    const f = c.features;
    const same =
      c.active &&
      c.default_return_url === want.default_return_url &&
      f.subscription_cancel.enabled &&
      f.subscription_cancel.mode === 'at_period_end' &&
      f.payment_method_update.enabled &&
      f.invoice_history.enabled &&
      !f.subscription_update.enabled &&
      !f.customer_update.enabled;
    if (same) return c;
    const u = await stripe.billingPortal.configurations.update(c.id, { ...want, active: true });
    notes.push(`updated Billing Portal configuration ${u.id}`);
    return u;
  }
  const c = await stripe.billingPortal.configurations.create(want);
  notes.push(`created Billing Portal configuration ${c.id}`);
  return c;
}

process.on('unhandledRejection', (e) => fail(`${e?.message ?? e}${e?.requestId ? ` (request ${e.requestId})` : ''}`));

const products = await shepetalProducts();
const lifetime = await product(products, 'lifetime', 'Shepetal');
const monthly = await product(products, 'monthly', 'Shepetal Monthly');
if (lifetime.id === monthly.id) fail('the lifetime and monthly products must be separate');
const lifetimePrice = await price('shepetal_lifetime', lifetime.id, cfg.lifetimeCents, cfg.lifetimeEur, false);
const monthlyPrice = await price('shepetal_monthly', monthly.id, cfg.monthlyCents, cfg.monthlyEur, true);
await archiveOtherPrices(lifetime.id, lifetimePrice.id);
await archiveOtherPrices(monthly.id, monthlyPrice.id);
const c = await coupon(lifetime.id);
const promo = await promotionCode(c.id);
const cfgPortal = await portal();

Object.assign(out, {
  lifetime_product: lifetime.id,
  lifetime_price: lifetimePrice.id,
  lifetime_amount: `${lifetimePrice.unit_amount} usd / ${cfg.lifetimeEur} eur once, tax ${cfg.taxBehavior}`,
  monthly_product: monthly.id,
  monthly_price: monthlyPrice.id,
  monthly_amount: `${monthlyPrice.unit_amount} usd / ${cfg.monthlyEur} eur a month, tax ${cfg.taxBehavior}`,
  site: cfg.site,
  coupon: `${c.id} (${c.amount_off} ${c.currency} off, ${c.duration}, applies_to ${c.applies_to?.products?.join(',') ?? '?'})`,
  promotion_code: `${promo.code} ${promo.id} (first_time_transaction ${promo.restrictions.first_time_transaction}, expires ${new Date(promo.expires_at * 1000).toISOString()})`,
  portal_configuration: cfgPortal.id,
  webhook_url: `${cfg.site}/api/stripe/webhook`,
  webhook_events: [
    'checkout.session.completed',
    'checkout.session.async_payment_succeeded',
    'customer.subscription.updated',
    'customer.subscription.deleted',
    'invoice.paid',
    'invoice.payment_failed',
    'charge.refunded',
  ].join(','),
});
for (const n of notes) console.log(`- ${n}`);
if (!notes.length) console.log('- nothing to change');
console.log(JSON.stringify(out, null, 2));
