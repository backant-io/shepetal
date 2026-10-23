import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import sitemap from '@/app/sitemap';
import { SiteFooter } from '@/components/site/Shell';
import { BlogArticlePage, BlogIndexPage } from '@/components/site/Blog';
import { SITE_URL } from './site';
import { copyProblems } from './brand-copy';
import { CLAIMS, COMPARISONS, ROWS } from './compare';
import { APPS, ARTICLES, BLOG, articleJsonLd, articleMetadata, factsOfArticle } from './blog';
import { PAGES, pageMetadata } from './seo';

const WEB = join(__dirname, '..', '..');
const BLOG_DIR = join(WEB, 'src', 'app', '(site)', 'blog');
const SLUGS = ['dictation-apps-mac', 'wispr-flow-vs-aqua-voice', 'wispr-flow-vs-willow', 'wispr-flow-vs-voiceink', 'dragon-mac'];

/** The index and every article: its path, its file, its rendered page, its metadata and the ?ref= its trial button carries. */
const PAGES_ = [
  {
    slug: 'index',
    path: '/blog',
    file: join(BLOG_DIR, 'page.tsx'),
    html: () => renderToStaticMarkup(<BlogIndexPage />),
    meta: () => pageMetadata('blog', { title: BLOG.title, description: BLOG.description }),
    tag: '<BlogIndexPage />',
    call: "pageMetadata('blog'",
    ref: 'blog',
  },
  ...SLUGS.map((slug) => ({
    slug,
    path: `/blog/${slug}`,
    file: join(BLOG_DIR, slug, 'page.tsx'),
    html: () => renderToStaticMarkup(<BlogArticlePage slug={slug} />),
    meta: () => articleMetadata(slug),
    tag: `<BlogArticlePage slug="${slug}" />`,
    call: `articleMetadata('${slug}')`,
    ref: `blog-${slug}`,
  })),
];

/** Each other app's own sites: a fact's source is one of these, never a review or a reseller. */
const OWN: Record<string, string[]> = {
  'wispr-flow': ['wisprflow.ai'],
  superwhisper: ['superwhisper.com'],
  macwhisper: ['www.macwhisper.com'],
  'apple-dictation': ['support.apple.com', 'www.apple.com'],
  'aqua-voice': ['aquavoice.com'],
  willow: ['willowvoice.com'],
  voiceink: ['tryvoiceink.com'],
  dragon: ['dragon.nuance.com'],
};
const ALL_OWN = Object.values(OWN).flat();

/** The other apps' names, allowed as text (and containing "whisper", which a model name would too). */
const NAMES = /Wispr Flow|Superwhisper|MacWhisper|Apple Dictation|Aqua Voice|Willow|VoiceInk|Dragon( Professional| Anywhere)?/g;

/** The text shepetal writes itself: the page without what it quotes about the other apps (cells and paragraphs with a source, the sources list, the JSON-LD). */
const ours = (html: string) =>
  html
    .replace(/<script[\s\S]*?<\/script>/g, ' ')
    .replace(/<section class="s-cmp-sources"[\s\S]*?<\/section>/g, ' ')
    .replace(/<td>(?:(?!<\/td>)[\s\S])*?s-cmp-src[\s\S]*?<\/td>/g, ' ')
    .replace(/<p data-sourced="">[\s\S]*?<\/p>/g, ' ')
    .replace(/<li>(?:(?!<\/li>)[\s\S])*?s-cmp-src[\s\S]*?<\/li>/g, ' ')
    .replace(/<td>Not on its pages\.<\/td>/g, ' ');

const text = (html: string) =>
  html
    .replace(/<script[\s\S]*?<\/script>/g, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&#x27;|&#39;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, '&')
    .replace(/\s+/g, ' ');

/** What a reader sees: the page text and the metadata. */
const words = (p: (typeof PAGES_)[number], only: (html: string) => string = (h) => h) => {
  const m = p.meta();
  return `${text(only(p.html()))} ${m.title} ${m.description}`;
};

describe('blog', () => {
  it('is the index and five articles, each with its own static page file', () => {
    expect(ARTICLES.map((a) => a.slug)).toEqual(SLUGS);
    for (const p of PAGES_) expect(existsSync(p.file), p.file).toBe(true);
  });

  it('is prerendered: static pages with no request data, no sign-in and nothing dynamic', () => {
    for (const p of PAGES_) {
      const src = readFileSync(p.file, 'utf8');
      expect(src, p.slug).toContain("export const dynamic = 'error';");
      expect(src, p.slug).toContain(p.tag);
      expect(src, p.slug).toContain(p.call);
    }
    for (const f of [join(WEB, 'src', 'components', 'site', 'Blog.tsx'), join(WEB, 'src', 'lib', 'blog.ts'), ...PAGES_.map((p) => p.file)]) {
      const src = readFileSync(f, 'utf8');
      expect(src, f).not.toMatch(/searchParams|\bauth\(|@\/lib\/auth|next\/headers|cookies\(|headers\(|force-dynamic|revalidate|'use cache'|@\/lib\/db|getCloudflareContext|async function|'use client'|fetch\(/);
    }
  });

  it('is in the sitemap on the domain, and linked from the footer', () => {
    const urls = sitemap().map((e) => e.url);
    expect(SITE_URL).toBe('https://shepetal.app');
    for (const p of PAGES_) expect(urls, p.path).toContain(`https://shepetal.app${p.path}`);
    expect(renderToStaticMarkup(<SiteFooter />)).toMatch(/<nav aria-label="Blog"[^>]*><a href="\/blog">Blog<\/a><\/nav>/);
  });

  it('gives each page a canonical on shepetal.app, its own title and description, and the blog’s link preview', () => {
    const titles = new Set<string>();
    for (const p of PAGES_) {
      const m = p.meta();
      expect(new URL(String(m.alternates?.canonical), SITE_URL).href).toBe(`https://shepetal.app${p.path}`);
      expect(m.openGraph?.url).toBe(p.path);
      const img = (m.openGraph?.images as { url: string }[])[0];
      expect(img.url).toBe('/og/blog.jpg');
      expect(existsSync(join(WEB, 'public', img.url))).toBe(true);
      expect(String(m.description).length).toBeGreaterThan(50);
      expect(String(m.description).length).toBeLessThanOrEqual(160);
      titles.add(String(m.title));
    }
    expect(titles.size).toBe(PAGES_.length);
    expect(PAGES.blog.path).toBe('/blog');
  });

  it('gives each article structured data on the domain: the Article and its breadcrumb', () => {
    for (const a of ARTICLES) {
      const ld = JSON.stringify(articleJsonLd(a));
      expect(ld).toContain(`"url":"https://shepetal.app/blog/${a.slug}"`);
      expect(ld).toContain('"@type":"BreadcrumbList"');
      expect(ld).not.toMatch(/backant\.io/i);
      expect(renderToStaticMarkup(<BlogArticlePage slug={a.slug} />)).toContain('<script type="application/ld+json">');
    }
  });

  it('has one H1 per page, a lede, and the trial button to /install?ref=blog-<slug>, with every download link the same', () => {
    for (const p of PAGES_) {
      const h = p.html();
      expect(h.match(/<h1\b/g), p.slug).toHaveLength(1);
      expect(h).toContain('class="s-lede"');
      const ctas = [...h.matchAll(/<a class="s-btn s-btn-signal" href="([^"]+)">([^<]+)<\/a>/g)];
      expect(ctas.length, p.slug).toBe(2);
      for (const [, href, label] of ctas) {
        expect(href).toBe(`/install?ref=${p.ref}`);
        expect(label).toBe('Try 30 days free');
      }
      expect(h.match(/href="\/(install|download)[^"]*"/g)?.every((x) => x === `href="/install?ref=${p.ref}"`)).toBe(true);
    }
  });

  it('links the site’s own pages with prefetch off and nothing from another host but the sources', () => {
    for (const p of PAGES_) {
      const h = p.html();
      expect(h, p.slug).not.toMatch(/<img|<svg|<picture|<iframe|<link /);
      for (const [, u] of h.matchAll(/href="(https?:[^"]+)"/g)) expect(ALL_OWN, `${p.slug}: ${u}`).toContain(new URL(u).hostname);
      for (const [, u] of h.matchAll(/href="(\/[^"]*)"/g)) expect(existsSync(join(WEB, 'src', 'app', '(site)', u.split('?')[0], 'page.tsx')) || u === '/' || u.startsWith('/install'), `${p.slug}: ${u}`).toBe(true);
    }
    const src = readFileSync(join(WEB, 'src', 'components', 'site', 'Blog.tsx'), 'utf8');
    for (const m of src.match(/<Link\b[^>]*>/g) ?? []) expect(m).toContain('prefetch={false}');
  });

  it('gives every fact about another app its own public source and a date in October 2026', () => {
    for (const app of Object.values(APPS)) {
      for (const [k, f] of Object.entries(app.facts)) {
        expect(ROWS.map((r) => r.key)).toContain(k);
        expect(f!.sources.length, `${app.key}: ${f!.text}`).toBeGreaterThan(0);
        for (const u of f!.sources) expect(OWN[app.key], `${app.key}: ${u}`).toContain(new URL(u).hostname);
        expect(f!.asOf).toMatch(/^2026-10-\d{2}$/);
      }
    }
    // the four apps with a comparison page bring the very same facts
    for (const c of COMPARISONS) expect(APPS[c.slug as keyof typeof APPS].facts).toBe(c.facts);
    for (const a of ARTICLES) {
      expect(a.updated).toMatch(/^2026-10-\d{2}$/);
      for (const s of a.sections) for (const p of s.paras) expect(Boolean(p.sources), p.text).toBe(Boolean(p.asOf));
      for (const g of a.picks) for (const p of g.picks) expect(Boolean(p.source), p.text).toBe(Boolean(p.asOf));
      // a paragraph or a pick that names another app either restates the table or carries its own source
      for (const s of a.sections) for (const p of s.paras) if (p.text.match(NAMES)) expect(p.sources?.every((u) => ALL_OWN.includes(new URL(u).hostname)), p.text).toBe(true);
      for (const p of [...a.sections.flatMap((s) => s.paras.flatMap((x) => x.sources ?? [])), ...a.picks.flatMap((g) => g.picks.flatMap((x) => (x.source ? [x.source] : [])))]) {
        expect(ALL_OWN).toContain(new URL(p).hostname);
      }
    }
    // As rendered: every cell and paragraph with another app's fact links out and has a <time>.
    for (const a of ARTICLES) {
      const h = renderToStaticMarkup(<BlogArticlePage slug={a.slug} />);
      const cells = [...h.matchAll(/<td>([\s\S]*?)<\/td>/g)].map((m) => m[1]).filter((c) => c.includes('s-cmp-src'));
      expect(cells.length, a.slug).toBe(factsOfArticle(a).reduce((n, x) => n + x.facts.length, 0));
      for (const c of [...cells, ...[...h.matchAll(/<p data-sourced="">([\s\S]*?)<\/p>/g)].map((m) => m[1])]) {
        expect(c, a.slug).toMatch(/<a href="https:\/\/[^"]+" rel="nofollow noopener"/);
        expect(c, a.slug).toMatch(/as of <time dateTime="2026-10-\d{2}">\d{1,2} October 2026<\/time>/);
      }
    }
  });

  it('lists every fact under Sources, with the full address of each source and the day it was checked', () => {
    for (const a of ARTICLES) {
      const h = renderToStaticMarkup(<BlogArticlePage slug={a.slug} />);
      const list = h.match(/<section class="s-cmp-sources"[\s\S]*?<\/section>/)?.[0] ?? '';
      expect(list, a.slug).toContain('>Sources</h2>');
      for (const { app, facts } of factsOfArticle(a)) {
        const items = [...(list.match(new RegExp(`<ul data-sources="${app.key}">([\\s\\S]*?)</ul>`))?.[1] ?? '').matchAll(/<li data-fact="([^"]+)">([\s\S]*?)<\/li>/g)];
        expect(items.map((m) => m[1]), `${a.slug}: ${app.key}`).toEqual(facts.map((f) => f.key));
        for (const [i, f] of facts.entries()) {
          for (const u of f.sources) expect(items[i][2]).toContain(`<a href="${u}" rel="nofollow noopener">${u}</a>`);
          expect(items[i][2]).toContain(`checked <time dateTime="${f.asOf}">`);
        }
      }
    }
  });

  it('keeps the brand rules: no banned line, no hedge, no em dash, no capital Shepetal, no model, no exclamation', () => {
    for (const p of PAGES_) {
      const t = words(p);
      expect(t, p.slug).not.toMatch(/hold (down )?(the )?fn|fn, (speak|talk)|speak, let go|let go|keeps quiet/i);
      expect(t, p.slug).not.toMatch(/\b(may|might|maybe|perhaps|probably|likely|arguably|generally|usually|typically|roughly|about|around|up to|approximately)\b/i);
      expect(t, p.slug).not.toContain('—');
      expect(t, p.slug).not.toContain('!');
      expect(t, p.slug).not.toMatch(/Shepetal|SHEPETAL/);
      const unnamed = t.replace(NAMES, ' ').replace(/\b[\w.-]+\.(ai|com)\b/g, ' ');
      expect(unnamed.match(/\bAI\b|artificial intelligence|neural|\bmodels?\b|\bwhisper\b|parakeet|nvidia|openai|\bgpt|llama|gemini|claude|anthropic|avalon/i)?.[0], p.slug).toBeUndefined();
      expect(t, p.slug).not.toMatch(/\b(better than|worse|slow(er)?|clunky|bad|poor|inferior|unlike|spy|leaks?|unsafe|insecure|best|dead|abandoned)\b/i);
      expect(t, p.slug).not.toMatch(/git[h]ub\.com|backant\.io/i);
    }
  });

  it('keeps Pavel’s voice in shepetal’s own words: the shared copy rules, plain headings, claims on their own line', () => {
    for (const p of PAGES_) {
      const h = ours(p.html());
      const t = words(p, ours).replace(NAMES, 'X');
      expect(copyProblems(t), p.slug).toEqual([]);
      expect(t, p.slug).not.toContain('?');
      expect(h.match(/<h[1-3][^>]*>[^<]*\.<\/h[1-3]>/)?.[0], p.slug).toBeUndefined();
      for (const c of CLAIMS) expect(t.split(c).length, `${p.slug}: ${c}`).toBe(h.split(`<span class="s-cmp-line">${c}</span>`).length);
      expect(t.match(/seamless|empower|unlock|leverage|game changer|cutting edge|revolutioni[sz]e|the future of|excited to|essentially|worth noting/i)?.[0], p.slug).toBeUndefined();
    }
  });

  it('writes no number of shepetal’s own but the trial, the two prices, macOS 14, the 25 languages, 24 hours, the claims and the dates', () => {
    const allowed = new Set(['30', '23.99', '0.99', '14', '25', '24', '100%', '4x']);
    for (const p of PAGES_) {
      const t = words(p, ours).replace(/(Updated|as of|checked) \d{1,2} October 2026/g, ' ');
      for (const n of t.match(/\d[\d.,]*(%|x\b)?/g) ?? []) expect(allowed.has(n.replace(/[.,]$/, '')), `${p.slug}: ${n}`).toBe(true);
      expect(t).toContain('$23.99 once. Yours forever.');
      expect(t).toContain('$0.99 a month.');
    }
  });
});
