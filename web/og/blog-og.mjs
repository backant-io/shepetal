#!/usr/bin/env node
// Builds the blog's link previews: public/blog/og/<slug>.jpg for every article, and blog.jpg for the index,
// from og/blog-og.html in headless Chrome, then JPEG with sips (macOS).
//
//   node og/blog-og.mjs            # from web/
//   CHROME=/path/to/chrome node og/blog-og.mjs
//
// The slugs, kinds and titles are read from src/content/blog/*.tsx, where each article object starts with
// slug, kind and title on their own lines.
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const WEB = join(dirname(fileURLToPath(import.meta.url)), '..');
const CHROME = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const OUT = join(WEB, 'public', 'blog', 'og');
const KIND = { comparison: 'Comparison', ranking: 'Ranking', guide: 'Guide' };

const dir = join(WEB, 'src', 'content', 'blog');
const items = [{ slug: 'blog', kicker: 'The shepetal blog', title: 'Dictation apps, compared.' }];
for (const f of readdirSync(dir).filter((f) => f.endsWith('.tsx'))) {
  const src = readFileSync(join(dir, f), 'utf8');
  for (const m of src.matchAll(/slug: '([^']+)',\s*\n\s*kind: '([^']+)',\s*\n\s*title: '((?:[^'\\]|\\.)+)'/g)) {
    items.push({ slug: m[1], kicker: KIND[m[2]], title: m[3].replace(/\\'/g, "'") });
  }
}

mkdirSync(OUT, { recursive: true });
const tmp = mkdtempSync(join(process.env.TMPDIR ?? tmpdir(), 'blog-og-'));
const page = pathToFileURL(join(WEB, 'og', 'blog-og.html'));
try {
  for (const it of items) {
    const url = new URL(page);
    url.search = new URLSearchParams({ k: it.kicker, t: it.title }).toString();
    const png = join(tmp, `${it.slug}.png`);
    execFileSync(CHROME, [
      '--headless=new',
      '--disable-gpu',
      '--hide-scrollbars',
      '--allow-file-access-from-files',
      `--user-data-dir=${join(tmp, 'profile')}`,
      '--window-size=1200,630',
      '--virtual-time-budget=2000',
      `--screenshot=${png}`,
      url.href,
    ], { stdio: 'ignore', timeout: 60_000 });
    execFileSync('sips', ['-s', 'format', 'jpeg', '-s', 'formatOptions', '84', png, '--out', join(OUT, `${it.slug}.jpg`)], { stdio: 'ignore' });
    console.log(`${it.slug}.jpg  ${it.title}`);
  }
} finally {
  rmSync(tmp, { recursive: true, force: true });
}
