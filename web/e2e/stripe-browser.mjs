// The hosted Stripe pages for web/e2e/stripe-testmode.mjs, driven in chrome-headless-shell (a plain binary: no window, no Dock icon, no focus).
// TEST mode only. Screenshots go to ../evidence/.
// web/e2e/stripe-testmode.mjs with BROWSER=1. playwright-core is not a dependency of web/: PLAYWRIGHT_CORE names its folder.
import { join } from 'node:path';

const { chromium } = await import(process.env.PLAYWRIGHT_CORE ? join(process.env.PLAYWRIGHT_CORE, 'index.mjs') : 'playwright-core');
const EVIDENCE = process.env.STRIPE_E2E_OUT ?? '.';
let browser;
async function page() {
  browser ??= await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ locale: 'en-US', viewport: { width: 1280, height: 900 } });
  return ctx.newPage();
}
export async function close() {
  await browser?.close();
  browser = undefined;
}
const text = async (p) => (await p.locator('body').innerText()).replace(/\s*\n\s*/g, ' | ');

/**
 * Stripe Checkout as a buyer uses it: USD, optionally a promotion code typed into "Add promotion code",
 * then the test card 4242 and Pay. Returns what the page said about the code and the total.
 */
export async function checkoutUI(url, { code, shot, pay = true, returnTo } = {}) {
  const p = await page();
  await p.goto(url, { waitUntil: 'load', timeout: 60000 });
  await p.locator('button[type="submit"]').waitFor({ timeout: 60000 });
  await p.waitForTimeout(1500);
  // Adaptive pricing offers the local currency: pick US dollars, the price we set.
  const usd = p.getByRole('button', { name: /^(USD|\$)/ }).first();
  if (await usd.count()) await usd.click().catch(() => {});
  let codeResult = null;
  if (code) {
    await p.locator('#promotionCode').fill(code);
    await p.getByRole('button', { name: 'Apply' }).click();
    await p.waitForTimeout(3000);
    const t = await text(p);
    const refusal = t.match(/[^|]*(doesn.t apply|isn.t valid|not valid|invalid|cannot be|can.t be)[^|]*/i)?.[0]?.trim();
    const off = t.match(/[^|]*\boff\b[^|]*/)?.[0]?.trim();
    codeResult = refusal ? { refused: refusal } : off ? { applied: off } : { unclear: t.slice(0, 300) };
  }
  const summary = await text(p);
  const codeField = (await p.locator('#promotionCode').count()) > 0;
  if (shot) await p.screenshot({ path: join(EVIDENCE, `${shot}.png`), fullPage: true });
  if (!pay) return { codeResult, summary, codeField };
  if (codeResult?.refused) {
    // Clear the refused code before paying.
    await p.locator('#promotionCode').fill('');
  }
  const card = p.locator('input[type="radio"][value="card"], #payment-method-accordion-item-title-card');
  if (await card.count()) await card.first().check({ force: true }).catch(() => card.first().click({ force: true }));
  else await p.getByText('Card', { exact: true }).first().click();
  await p.locator('#cardNumber').waitFor({ timeout: 15000 });
  await p.locator('#cardNumber').fill('4242 4242 4242 4242');
  await p.locator('#cardExpiry').fill('12 / 34');
  await p.locator('#cardCvc').fill('123');
  await p.locator('#billingName').fill('Test Buyer').catch(() => {});
  if (await p.locator('#billingCountry').count()) await p.locator('#billingCountry').selectOption('US').catch(() => {});
  if (await p.locator('#billingPostalCode').count()) await p.locator('#billingPostalCode').fill('94103').catch(() => {});
  if (shot) await p.screenshot({ path: join(EVIDENCE, `${shot}-card.png`), fullPage: true });
  await p.locator('button[type="submit"]').click();
  await p.waitForURL((u) => u.href.startsWith(returnTo), { timeout: 60000 });
  await p.context().close();
  return { codeResult, summary, codeField };
}

/** The Billing Portal as a subscriber uses it: Cancel subscription, then confirm. */
export async function portalCancelUI(url, { shot = 'portal' } = {}) {
  const p = await page();
  await p.goto(url, { waitUntil: 'load', timeout: 60000 });
  await p.getByText('Cancel subscription', { exact: true }).first().waitFor({ timeout: 60000 });
  await p.screenshot({ path: join(EVIDENCE, `${shot}-1-before.png`), fullPage: true });
  const before = await text(p);
  await p.getByText('Cancel subscription', { exact: true }).first().click();
  await p.waitForTimeout(3000);
  await p.screenshot({ path: join(EVIDENCE, `${shot}-2-confirm.png`), fullPage: true });
  const confirmPage = await text(p);
  await p.locator('[data-testid="confirm"], button:has-text("Cancel subscription")').first().click();
  await p.waitForTimeout(6000);
  await p.screenshot({ path: join(EVIDENCE, `${shot}-3-after.png`), fullPage: true });
  const after = await text(p);
  await p.context().close();
  return { before, confirmPage, after };
}
