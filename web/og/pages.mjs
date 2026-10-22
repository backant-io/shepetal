#!/usr/bin/env node
// Renders the link previews of the public pages (src/lib/pages.json) from og/pages.html into public/og/<key>.jpg,
// 1200 x 630, in chromium headless shell. Run it after a page's title or sub line changes:
//   PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core node og/pages.mjs
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { shepetalDomain } from '../domain.config.mjs';

const WEB = join(dirname(fileURLToPath(import.meta.url)), '..');
const { chromium } = await import(process.env.PLAYWRIGHT_CORE ? join(process.env.PLAYWRIGHT_CORE, 'index.mjs') : 'playwright-core');
const pages = JSON.parse(readFileSync(join(WEB, 'src/lib/pages.json'), 'utf8'));
const out = join(WEB, 'public/og');
mkdirSync(out, { recursive: true });
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
  for (const [key, p] of Object.entries(pages)) {
    const q = new URLSearchParams({ title: p.title, sub: p.sub, host: shepetalDomain(), path: p.path === '/' ? '' : p.path });
    await page.goto(`file://${join(WEB, 'og/pages.html')}?${q}`);
    await page.evaluate(() => document.fonts.ready);
    const png = join(out, `${key}.png`);
    await page.screenshot({ path: png });
    execFileSync('sips', ['-s', 'format', 'jpeg', '-s', 'formatOptions', '85', png, '--out', join(out, `${key}.jpg`)], { stdio: 'ignore' });
    rmSync(png);
    console.log(`public/og/${key}.jpg`);
  }
} finally {
  await browser.close();
}
