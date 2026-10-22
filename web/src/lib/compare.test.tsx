import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import sitemap from '@/app/sitemap';
import { SiteFooter } from '@/components/site/Shell';
import { ComparePage, GuidePage } from '@/components/site/Compare';
import { TRY as STORY_TRY } from '@/components/story/Story';
import { SITE_URL } from './site';
import { COMPARISONS, GUIDES, ROWS, TRY, comparisonMetadata, guideMetadata } from './compare';

const WEB = join(__dirname, '..', '..');
const SITE = join(WEB, 'src', 'app', '(site)');
const APPS = ['wispr-flow', 'superwhisper', 'macwhisper', 'apple-dictation'];
const SEO = ['offline-dictation-mac', 'private-dictation-mac'];

/** Every new page: its path, its file, its component, its metadata and the ?ref= its trial button carries. */
const PAGES_ = [
  ...APPS.map((slug) => ({
    slug,
    path: `/compare/${slug}`,
    file: join(SITE, 'compare', slug, 'page.tsx'),
    html: () => renderToStaticMarkup(<ComparePage slug={slug} />),
    meta: () => comparisonMetadata(slug),
    call: `comparisonMetadata('${slug}')`,
    tag: `<ComparePage slug="${slug}" />`,
    ref: `compare-${slug}`,
  })),
  ...SEO.map((slug) => ({
    slug,
    path: `/${slug}`,
    file: join(SITE, slug, 'page.tsx'),
    html: () => renderToStaticMarkup(<GuidePage slug={slug} />),
    meta: () => guideMetadata(slug),
    call: `guideMetadata('${slug}')`,
    tag: `<GuidePage slug="${slug}" />`,
    ref: slug === 'offline-dictation-mac' ? 'seo-offline' : 'seo-private',
  })),
];

/** The other apps' names, which are allowed as text (and contain "whisper", which a model name would too). */
const NAMES = /Wispr Flow|Superwhisper|MacWhisper|Apple Dictation/g;
/** An "as of" date, the one number on these pages that is not shepetal's. */
const AS_OF = /as of \d{1,2} (January|February|March|April|May|June|July|August|September|October|November|December) \d{4}/g;

/** What a reader sees: the page text and the metadata. */
const words = (p: (typeof PAGES_)[number]) => {
  const m = p.meta();
  const page = p
    .html()
    .replace(/<[^>]+>/g, ' ')
    .replace(/&#x27;|&#39;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, '&')
    .replace(/\s+/g, ' ');
  return `${page} ${m.title} ${m.description}`;
};

describe('comparison pages', () => {
  it('are the four apps and the two guides, each with its own page file', () => {
    expect(COMPARISONS.map((c) => c.slug)).toEqual(APPS);
    expect(GUIDES.map((g) => g.slug)).toEqual(SEO);
    for (const p of PAGES_) expect(existsSync(p.file), p.file).toBe(true);
  });

  it('are prerendered: static pages with no request data, no sign-in and nothing dynamic', () => {
    for (const p of PAGES_) {
      const src = readFileSync(p.file, 'utf8');
      expect(src, p.slug).toContain("export const dynamic = 'error';");
      expect(src, p.slug).toContain(p.tag);
      expect(src, p.slug).toContain(p.call);
    }
    for (const f of [join(WEB, 'src', 'components', 'site', 'Compare.tsx'), join(WEB, 'src', 'lib', 'compare.ts'), ...PAGES_.map((p) => p.file)]) {
      const src = readFileSync(f, 'utf8');
      expect(src, f).not.toMatch(/searchParams|\bauth\(|@\/lib\/auth|next\/headers|cookies\(|headers\(|force-dynamic|revalidate|'use cache'|@\/lib\/db|getCloudflareContext|async function|'use client'/);
    }
  });

  it('are in the sitemap on the domain', () => {
    const urls = sitemap().map((e) => e.url);
    expect(SITE_URL).toBe('https://shepetal.app');
    for (const p of PAGES_) expect(urls, p.path).toContain(`https://shepetal.app${p.path}`);
  });

  it('each have a canonical on shepetal.app, their own title and description, and the landing page’s link preview', () => {
    const titles = new Set<string>();
    for (const p of PAGES_) {
      const m = p.meta();
      expect(new URL(String(m.alternates?.canonical), SITE_URL).href).toBe(`https://shepetal.app${p.path}`);
      expect(m.openGraph?.url).toBe(p.path);
      const img = (m.openGraph?.images as { url: string }[])[0];
      expect(img.url).toBe('/og/home.jpg');
      expect(existsSync(join(WEB, 'public', img.url))).toBe(true);
      expect(String(m.description).length).toBeGreaterThan(50);
      expect(String(m.description).length).toBeLessThanOrEqual(160);
      titles.add(String(m.title));
    }
    expect(titles.size).toBe(PAGES_.length);
    // not the use-case page's title either
    expect(titles.has('Private dictation for Mac')).toBe(false);
  });

  it('each have one H1, a lede, and the trial button "Try 30 days free" to /install with the page’s ref', () => {
    expect(TRY).toBe(STORY_TRY);
    for (const p of PAGES_) {
      const h = p.html();
      expect(h.match(/<h1\b/g), p.slug).toHaveLength(1);
      expect(h).toContain('class="s-lede"');
      const ctas = [...h.matchAll(/<a class="s-btn s-btn-signal" href="([^"]+)">([^<]+)<\/a>/g)];
      expect(ctas.length, p.slug).toBe(2);
      for (const [, href, text] of ctas) {
        expect(href).toBe(`/install?ref=${p.ref}`);
        expect(text).toBe('Try 30 days free');
      }
      expect(h.match(/href="\/(install|download)[^"]*"/g)?.every((x) => x === `href="/install?ref=${p.ref}"`)).toBe(true);
    }
  });

  it('give every fact about another app its public source and an "as of" date', () => {
    for (const c of COMPARISONS) {
      expect(Object.keys(c.facts).sort(), c.slug).toEqual(ROWS.map((r) => r.key).sort());
      for (const f of Object.values(c.facts)) {
        expect(f.sources.length, `${c.slug}: ${f.text}`).toBeGreaterThan(0);
        for (const u of f.sources) expect(u, c.slug).toMatch(/^https:\/\/[^/]+\.[a-z]+/);
        expect(f.asOf).toMatch(/^\d{4}-\d{2}-\d{2}$/);
      }
      for (const p of [...c.pickOther, ...c.pickShepetal]) expect(Boolean(p.source), p.text).toBe(Boolean(p.asOf));
    }
    // As rendered: every row of every table with another app in it has a link out and a <time>.
    for (const p of PAGES_) {
      const h = p.html();
      const rows = [...h.matchAll(/<tr data-row="[^"]+">([\s\S]*?)<\/tr>/g)].map((m) => m[1]);
      expect(rows.length, p.slug).toBe(p.path.startsWith('/compare/') ? ROWS.length : COMPARISONS.length);
      for (const r of rows) {
        const cells = [...r.matchAll(/<td>([\s\S]*?)<\/td>/g)].map((m) => m[1]);
        const theirs = p.path.startsWith('/compare/') ? cells.slice(1) : cells;
        for (const cell of theirs) {
          expect(cell, p.slug).toMatch(/<a href="https:\/\/[^"]+" rel="nofollow noopener"/);
          expect(cell, p.slug).toMatch(/as of <time dateTime="\d{4}-\d{2}-\d{2}">\d{1,2} [A-Z][a-z]+ \d{4}<\/time>/);
        }
      }
    }
  });

  it('use the other apps’ names as text only: no logo, no image of theirs', () => {
    for (const p of PAGES_) {
      const h = p.html();
      expect(h, p.slug).not.toMatch(/<img|<svg|<picture/);
      for (const name of ['Wispr Flow', 'Superwhisper', 'MacWhisper', 'Apple Dictation']) expect(h).not.toMatch(new RegExp(`alt="[^"]*${name}`));
    }
  });

  it('keep the voice: none of the banned lines, no model, no hedge, no exclamation, no disparagement', () => {
    for (const p of PAGES_) {
      const t = words(p);
      expect(t, p.slug).not.toMatch(/hold (down )?(the )?fn|fn, speak|speak, let go|let go|keeps quiet/i);
      // the names and the source links' hostnames (wisprflow.ai) aside
      const unnamed = t.replace(NAMES, ' ').replace(/\b[\w.-]+\.(ai|com)\b/g, ' ');
      expect(unnamed.match(/\bAI\b|artificial intelligence|neural|\bmodels?\b|\bwhisper\b|parakeet|nvidia|openai|\bgpt|llama|canary|wav2vec|vosk|deepgram|gemini|claude|anthropic|ollama|\bS1\b/i)?.[0], p.slug).toBeUndefined();
      expect(t, p.slug).not.toMatch(/\b(may|might|maybe|perhaps|could|probably|likely|should|arguably|generally|usually)\b/i);
      expect(t, p.slug).not.toContain('!');
      expect(t, p.slug).not.toMatch(/Shepetal|SHEPETAL/);
      expect(t, p.slug).not.toMatch(/\b(better than|worse|slow(er)?|clunky|bad|poor|inferior|unlike|spy|leaks?|unsafe|insecure|best)\b/i);
      expect(t, p.slug).not.toMatch(/git[h]ub\.com|backant\.io/i);
    }
  });

  it('publish no number but the trial, the two prices, macOS 14.4, the 25 languages, the approved claims and the "as of" dates', () => {
    const allowed = new Set(['30', '23.99', '0.99', '14.4', '25', '100%', '4x']);
    for (const p of PAGES_) {
      const t = words(p);
      for (const n of t.replace(AS_OF, ' ').match(/\d[\d.,]*(%|x\b)?/g) ?? []) expect(allowed.has(n.replace(/[.,]$/, '')), `${p.slug}: ${n}`).toBe(true);
      expect(t.match(AS_OF)?.length, p.slug).toBeGreaterThan(0);
      // the claims only word for word
      for (const m of t.match(/100%[^.]*\./g) ?? []) expect(m).toBe('100% private.');
      expect(t.match(/100% private\. \S+ \S+ \S+\./g)?.every((m) => m === '100% private. Your data is yours.') ?? true).toBe(true);
      for (const m of t.match(/4x[^.]*\./g) ?? []) expect(m).toBe('4x faster than typing.');
      for (const m of t.match(/Meetings, [^.]*\./g) ?? []) expect(m).toBe('Meetings, transcribed on your Mac.');
      for (const m of t.match(/Works in every app[^.]*\./g) ?? []) expect(m).toBe('Works in every app.');
      for (const m of t.match(/Works offline[^.]*\./g) ?? []) expect(m).toBe('Works offline.');
      // the prices exactly as on the landing page
      expect(t).toContain('$23.99 once. Yours forever.');
      expect(t).toContain('$0.99 a month.');
      expect(t.match(/\$[\d.]+[^.]*\./g)?.every((m) => m === '$23.99 once.' || m === '$0.99 a month.')).toBe(true);
      expect(t.match(/\$\d/g)?.length).toBe(t.match(/\$(23\.99|0\.99)/g)?.length);
    }
  });

  it('are linked from the site footer’s "Compare" list', () => {
    const f = renderToStaticMarkup(<SiteFooter />);
    const nav = f.match(/<nav aria-label="Compare"[\s\S]*?<\/nav>/)?.[0] ?? '';
    expect(nav.match(/href="[^"]+"/g)).toEqual(PAGES_.map((p) => `href="${p.path}"`));
    expect(nav).toContain('Compare');
    expect(nav).toContain('>Wispr Flow<');
  });
});
