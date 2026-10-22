#!/usr/bin/env node
// The landing page against the approved design ("full scroll story"), in chromium headless shell (no window, no focus).
//
//   1. frames: the reference renders in DESIGN_FRAMES (rA..rE = the hero and chapters 1-4 at 1440x900, ph1/ph4 =
//      chapters 1 and 4 at 390x844; the filename suffix is the scroll % of that chapter's pin). The build is captured
//      at the same scroll position, and the share of pixels whose largest channel differs by more than 32/255 is
//      reported. Side-by-side sheets (design left, build right) go to OUT, every side under 2000 px.
//   2. sweep (SWEEP=1): chapters 5 and 6 have no reference frames, so the design's standalone preview
//      (DESIGN_HTML) and the build are captured at p = 0, .1 .. 1 of every chapter and at the page bottom.
//      The preview lacks the 🤫 image (shush.svg) and the canvas runtime's key measuring, so the docking flight
//      (hero 80-98 %) and the 🤫 differ there by design.
//   3. overlap: the hero key, the docked key and the 🤫 are checked against every visible line of text at many
//      window sizes, at every step of a top-to-bottom scroll: in the pinned chapters, and between them, where a
//      headline scrolls past the fixed corner (the corner steps aside then, see StoryMotion's clear).
//
// Only viewport-sized captures, never a full-page screenshot. Exit 1 when a frame differs by more than 1 % or the
// key covers text.
//
//   PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core BASE=http://localhost:3000 OUT=/tmp/design-match \
//     node e2e/design-match.mjs
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const { chromium } = await import(process.env.PLAYWRIGHT_CORE ? join(process.env.PLAYWRIGHT_CORE, 'index.mjs') : 'playwright-core');
const BASE = process.env.BASE ?? 'http://localhost:3000';
const OUT = process.env.OUT ?? './design-match';
const DESIGN = process.env.DESIGN_DIR ?? `${process.env.HOME}/shepetal-agent/brief/design`;
const FRAMES = process.env.DESIGN_FRAMES ?? join(DESIGN, 'frames');
const DESIGN_HTML = process.env.DESIGN_HTML ?? `file://${join(DESIGN, 'index.html')}`;
const TRACK = { rA: 0, rB: 1, rC: 2, rD: 3, rE: 4, ph1: 1, ph4: 4 };
mkdirSync(OUT, { recursive: true });
let failed = 0;

async function open(ctx, url) {
  const page = await ctx.newPage();
  await page.goto(url, { waitUntil: 'networkidle' });
  await page.evaluate(() => document.fonts.ready);
  return page;
}
/** Scrolls to p of chapter i's pin (i < 0: the page bottom), as a reader would, and captures the viewport. */
async function capture(page, i, p) {
  const y = await page.evaluate(([i, p]) => {
    if (i < 0) return document.documentElement.scrollHeight - innerHeight;
    const r = document.querySelectorAll('.kc-track')[i].getBoundingClientRect();
    return window.scrollY + r.top + p * (r.height - innerHeight);
  }, [i, p]);
  for (const wait of [400, 300]) {
    await page.evaluate((y) => window.scrollTo(0, y), y);
    await page.waitForTimeout(wait);
  }
  return page.screenshot();
}
/** Percent of pixels whose largest channel differs by more than 32. */
async function diff(page, a, b) {
  return page.evaluate(async ([a, b]) => {
    const load = (src) => new Promise((ok) => { const i = new Image(); i.onload = () => ok(i); i.src = src; });
    const [ia, ib] = await Promise.all([load(a), load(b)]);
    const w = ia.width, h = ia.height;
    const pixels = (img) => { const c = new OffscreenCanvas(w, h).getContext('2d'); c.drawImage(img, 0, 0); return c.getImageData(0, 0, w, h).data; };
    const da = pixels(ia), db = pixels(ib);
    let n = 0;
    for (let i = 0; i < da.length; i += 4) if (Math.max(Math.abs(da[i] - db[i]), Math.abs(da[i + 1] - db[i + 1]), Math.abs(da[i + 2] - db[i + 2])) > 32) n++;
    return (100 * n) / (w * h);
  }, [a, b].map((x) => 'data:image/png;base64,' + x.toString('base64')));
}
async function sheet(browser, name, ref, mine, width, height) {
  const scale = width * 2 + 24 > 1990 ? 0.5 : 1, w = Math.round(width * scale), h = Math.round(height * scale);
  const page = await browser.newPage({ viewport: { width: w * 2 + 24, height: h + 30 }, deviceScaleFactor: 1 });
  const img = (b) => `data:image/png;base64,${b.toString('base64')}`;
  await page.setContent(`<body style="margin:0;background:#888;font:12px monospace;color:#fff"><div style="display:flex;gap:24px">${[['design', ref], ['build', mine]].map(([t, b]) => `<figure style="margin:0"><figcaption style="height:30px;line-height:30px">${t} ${name}</figcaption><img src="${img(b)}" width="${w}" height="${h}"></figure>`).join('')}</div></body>`);
  writeFileSync(join(OUT, `side-${name}.png`), await page.screenshot());
  await page.close();
}

const browser = await chromium.launch({ headless: true });
try {
  const cmp = await browser.newPage();
  // 1. the reference frames
  console.log('# frames: design render vs build at the same scroll position');
  const names = readdirSync(FRAMES).filter((f) => /^(r[A-E]|ph\d)-\d+-\d+\.png$/.test(f)).map((f) => f.replace('.png', '')).sort();
  const ctxs = {};
  for (const name of names) {
    const [key, w, pct] = name.split('-');
    const width = +w, height = width <= 760 ? 844 : 900;
    ctxs[width] ??= await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 1 });
    const page = await open(ctxs[width], BASE + '/');
    const mine = await capture(page, TRACK[key], +pct / 100);
    await page.close();
    writeFileSync(join(OUT, `${name}.png`), mine);
    const ref = readFileSync(join(FRAMES, `${name}.png`));
    const d = await diff(cmp, ref, mine);
    await sheet(browser, name, ref, mine, width, height);
    if (d > 1) failed++;
    console.log(`${name.padEnd(14)} ${String(width)}x${height} ${d.toFixed(2)}% of pixels differ${d > 1 ? '  FAIL' : ''}`);
  }
  for (const c of Object.values(ctxs)) await c.close();

  // 2. the sweep against the standalone preview
  if (process.env.SWEEP) {
    console.log('\n# sweep: design index.html vs build, every chapter at p = 0 .. 1 and the page bottom');
    for (const [width, height] of [[1440, 900], [390, 844]]) {
      const ctx = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 1 });
      const a = await open(ctx, DESIGN_HTML), b = await open(ctx, BASE + '/');
      const ha = await a.evaluate(() => document.documentElement.scrollHeight), hb = await b.evaluate(() => document.documentElement.scrollHeight);
      console.log(`${width}x${height}: page height design ${ha}, build ${hb}${ha === hb ? '' : '  FAIL'}`);
      if (ha !== hb) failed++;
      const n = await b.evaluate(() => document.querySelectorAll('.kc-track').length);
      const rows = [];
      for (let i = -1; i < n; i++) for (const p of i < 0 ? [1] : [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1]) {
        const d = await diff(cmp, await capture(a, i, p), await capture(b, i, p));
        rows.push(`${i < 0 ? 'end' : `ch${i} ${String(Math.round(p * 100)).padStart(3)}%`} ${d.toFixed(2)}%`);
      }
      console.log('  ' + rows.join(' | '));
      await ctx.close();
    }
  }

  // 3. the key never covers text in a pinned chapter
  console.log('\n# overlap: the keys and the 🤫 against every visible line of text');
  const SIZES = [[1440, 900], [1280, 720], [1366, 768], [1024, 768], [1920, 1080], [2560, 1440], [1440, 600], [1600, 500], [1200, 1600],
    [900, 1400], [820, 1180], [768, 1024], [761, 700], [760, 900], [414, 896], [390, 844], [375, 667], [360, 640], [320, 568]];
  for (const [width, height] of process.env.QUICK ? SIZES.slice(0, 3).concat([[390, 844]]) : SIZES) {
    const ctx = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 1 });
    const page = await open(ctx, BASE + '/');
    const max = await page.evaluate(() => document.documentElement.scrollHeight - innerHeight);
    const pinnedHits = new Set(), transitHits = new Set();
    for (let s = 0; s <= 90; s++) {
      await page.evaluate((y) => window.scrollTo(0, y), Math.round((max * s) / 90));
      await page.waitForTimeout(60);
      // let the IntersectionObserver deliver and the corner's fade finish
      await page.evaluate(() => new Promise((ok) => requestAnimationFrame(() => requestAnimationFrame(ok))));
      await page.waitForFunction(() => !document.querySelector('.kc-corner')?.getAnimations().length, null, { timeout: 2000 }).catch(() => {});
      const found = await page.evaluate(() => {
        const opacity = (el) => {
          let o = 1;
          for (let e = el; e && e.nodeType === 1; e = e.parentElement) {
            const cs = getComputedStyle(e);
            if (cs.display === 'none' || cs.visibility === 'hidden') return 0;
            o *= +cs.opacity;
          }
          return o;
        };
        const moving = (el) => {
          for (let e = el; e && e.nodeType === 1; e = e.parentElement)
            if (e.getAnimations().some((a) => { const p = a.effect?.getComputedTiming().progress; return p != null && p > 0.001 && p < 0.999 && /^kc-(wx|wy|flow|in|pop|slide|dockin|dockout)$/.test(a.animationName); })) return true;
          return false;
        };
        const pinned = [...document.querySelectorAll('.kc-track')].some((t) => { const r = t.getBoundingClientRect(); return r.top <= 0.5 && r.bottom >= innerHeight - 0.5; });
        const keys = [];
        for (const sel of ['.kc-k-cap', '.kd-k-cap', '.kc-shf']) {
          const el = document.querySelector(sel);
          if (!el || opacity(el) < 0.05 || moving(el)) continue;
          const r = el.getBoundingClientRect();
          if (r.width && r.bottom > 0 && r.top < innerHeight) keys.push({ sel, r });
        }
        const out = [];
        const walker = document.createTreeWalker(document.querySelector('.kc'), NodeFilter.SHOW_TEXT);
        for (let n = walker.nextNode(); n; n = walker.nextNode()) {
          if (!n.textContent.trim()) continue;
          const p = n.parentElement;
          if (p.closest('svg') || opacity(p) < 0.05 || moving(p)) continue;
          const range = document.createRange();
          range.selectNodeContents(n);
          for (const t of range.getClientRects()) {
            if (t.bottom < 0 || t.top > innerHeight) continue;
            for (const k of keys) {
              const ix = Math.min(t.right, k.r.right) - Math.max(t.left, k.r.left), iy = Math.min(t.bottom, k.r.bottom) - Math.max(t.top, k.r.top);
              if (ix > 1 && iy > 1) out.push({ pinned, what: `${k.sel} covers "${n.textContent.trim().slice(0, 30)}"` });
            }
          }
        }
        return out;
      });
      for (const f of found) (f.pinned ? pinnedHits : transitHits).add(f.what);
    }
    if (pinnedHits.size || transitHits.size) failed++;
    const say = (set, where) => (set.size ? `OVERLAP ${where}: ${[...set].join('; ')}` : `clear ${where}`);
    console.log(`${width}x${height}: ${say(pinnedHits, 'in the pinned chapters')}, ${say(transitHits, 'between them')}`);
    await ctx.close();
  }
} finally {
  await browser.close();
}
console.log(failed ? `\ndesign-match: ${failed} FAILED` : '\ndesign-match: OK');
process.exit(failed ? 1 : 0);
