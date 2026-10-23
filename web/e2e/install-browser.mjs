#!/usr/bin/env node
// /install and the links in chromium headless shell (no window, no focus), against a running Worker (wrangler dev on
// a build, or a preview URL):
//   1. /install?ref=x&utm_source=y starts the download by itself: the inline script worker.ts adds (edge-html.ts)
//      navigates to /download?ref=x&utm_source=y. That request is aborted, so nothing downloads.
//   2. No next/link prefetch: a prefetch is a Worker request, and the Workers Free plan's daily requests are shared by
//      the account. Scrolling a page with links in view asks for no RSC payload; a click still navigates, with one.
//
//   PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core BASE=http://localhost:8787 node e2e/install-browser.mjs
import assert from 'node:assert/strict';
import { join } from 'node:path';

const { chromium } = await import(process.env.PLAYWRIGHT_CORE ? join(process.env.PLAYWRIGHT_CORE, 'index.mjs') : 'playwright-core');
const BASE = process.env.BASE ?? 'http://localhost:8787';
const browser = await chromium.launch({ headless: true });
let failed = 0;
async function check(name, fn) {
  const page = await browser.newPage();
  try {
    await fn(page);
    console.log(`ok - ${name}`);
  } catch (e) {
    failed++;
    console.log(`not ok - ${name}\n    ${e.message.split('\n').join('\n    ')}`);
  } finally {
    await page.close();
  }
}

await check('/install?ref=x&utm_source=y navigates to /download?ref=x&utm_source=y by itself, about 1 s after it shows', async (page) => {
  let shown = 0;
  const started = new Promise((resolve) =>
    page.route(/\/download(\?|$)/, (route) => {
      resolve({ url: route.request().url(), after: Date.now() - shown, nav: route.request().isNavigationRequest() });
      route.abort();
    }),
  );
  await page.goto(`${BASE}/install?ref=x&utm_source=y`, { waitUntil: 'domcontentloaded' });
  shown = Date.now();
  // Read before the script navigates: the aborted /download replaces the page with the browser's error page.
  const meta = await page.locator('meta[http-equiv="refresh" i]').count();
  const link = await page.locator('a', { hasText: 'download shepetal' }).getAttribute('href');
  const { url, after, nav } = await Promise.race([started, new Promise((_, no) => setTimeout(() => no(new Error('no navigation to /download within 5 s')), 5000))]);
  assert.equal(new URL(url).pathname + new URL(url).search, '/download?ref=x&utm_source=y');
  assert.ok(nav, 'a navigation, as a download is');
  assert.ok(after > 500 && after < 3000, `after ${after} ms`);
  assert.equal(meta, 0, 'no meta refresh');
  assert.equal(link, '/download?ref=x&utm_source=y', 'the fallback link');
});

await check('no RSC prefetch while links are in view; a click on one still navigates, with one request', async (page) => {
  const rsc = [];
  page.on('request', (r) => r.headers().rsc === '1' && rsc.push(r.url()));
  await page.goto(`${BASE}/faq`, { waitUntil: 'networkidle' });
  for (let i = 0; i < 20; i++) await page.mouse.wheel(0, 600);
  await page.waitForTimeout(1500);
  assert.deepEqual(rsc, [], 'no prefetch');
  await page.locator('footer a', { hasText: 'Privacy' }).click();
  await page.waitForURL(`${BASE}/privacy`);
  await page.locator('h1').first().waitFor();
  assert.match(await page.title(), /Privacy/);
  assert.equal(rsc.length, 1, `one request for the page: ${rsc.join(', ')}`);
});

await browser.close();
process.exit(failed ? 1 : 0);
