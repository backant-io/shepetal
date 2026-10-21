import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createElement, Fragment } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { BLOG_CSS } from '../../app/(site)/blog/blog-css';
import robots from '../../app/robots';
import sitemap from '../../app/sitemap';
import { APPS } from './apps';
import { ARTICLES, bySlug } from './articles';
import { articleJsonLd, CTA_CLAIMS, SITE } from './seo';
import type { Article } from './types';

// The blog's rules: the brief for the blog (bold voice, true facts, each competitor linked once), the brand
// (brand/voice.md: no em dashes, no hedges, no model names, lowercase shepetal, no price in link previews)
// and technical SEO (titles, descriptions, canonical pages, internal links, structured data).

const WEB = join(__dirname, '..', '..', '..');
const html = (a: Article) =>
  renderToStaticMarkup(
    createElement(
      Fragment,
      null,
      a.short,
      ...a.sections.map((s) => createElement('section', { key: s.id }, createElement('h2', null, s.title), s.body)),
      ...a.faq.map((f) => createElement('p', { key: f.q }, `${f.q} ${f.a}`)),
    ),
  );
// What a reader sees: the markup without tags, plus the title, the lead and the description.
const text = (a: Article) =>
  [a.title, a.seoTitle, a.dek, a.description, html(a).replace(/<[^>]+>/g, ' ')].join('\n').replace(/&#x27;/g, "'").replace(/&amp;/g, '&');
const hrefs = (a: Article) => [...html(a).matchAll(/href="([^"]+)"/g)].map((m) => m[1]);

describe('blog articles', () => {
  it('has the articles the brief asks for', () => {
    const slugs = ARTICLES.map((a) => a.slug);
    for (const s of [
      'wispr-flow-vs-superwhisper',
      'wispr-flow-vs-macwhisper',
      'wispr-flow-vs-aqua-voice',
      'wispr-flow-vs-willow',
      'wispr-flow-vs-voiceink',
      'wispr-flow-vs-apple-dictation',
      'wispr-flow-vs-dragon',
      'wispr-flow-alternatives',
      'best-dictation-apps-mac',
      'best-local-dictation-apps',
    ]) {
      expect(slugs).toContain(s);
    }
    expect(new Set(slugs).size).toBe(slugs.length);
  });

  it('gives every article its own short title with the keyword, and a description that fits a search result', () => {
    const seen = new Set<string>();
    for (const a of ARTICLES) {
      expect(a.seoTitle.length, a.seoTitle).toBeLessThanOrEqual(60);
      expect(a.description.length, `${a.slug}: ${a.description.length}`).toBeGreaterThanOrEqual(110);
      expect(a.description.length, `${a.slug}: ${a.description.length}`).toBeLessThanOrEqual(160);
      expect(a.seoTitle.toLowerCase(), a.slug).toContain(a.keyword.toLowerCase());
      for (const v of [a.seoTitle, a.title, a.description]) {
        expect(seen.has(v), v).toBe(false);
        seen.add(v);
      }
    }
  });

  it('keeps the price out of every link preview (title, description), as the brand asks', () => {
    for (const a of ARTICLES) {
      expect(`${a.title} ${a.seoTitle} ${a.description}`, a.slug).not.toMatch(/\$|€|£|\d+(\.\d+)?\s?(USD|EUR|dollars?)|\/mo\b/i);
    }
  });

  it('writes the bold voice: no em dashes, footnotes, hedges, hype or banned lines', () => {
    const banned = [
      /—/,
      /\*|†|‡|¹|²|³/,
      /!/,
      /\b(about|around|roughly|up to|depending on|measured on|after setup|may|might|typically|approximately)\b/i,
      /\b(magic|magical|revolutionary|game.changer|supercharge|unlock|empower|leverage|cutting-edge|next-gen|blazing|lightning|simply|easily|just|please|deal|cheap|steal|bargain|no-brainer|risk-free|killer|beats|better than|unhackable|military-grade|bank-level)\b/i,
      /hold fn,? (speak|talk)|keeps quiet|quiet dictation|the quiet way/i,
    ];
    for (const a of ARTICLES) {
      const t = text(a);
      for (const re of banned) {
        const m = re.exec(t);
        expect(m && t.slice(Math.max(0, m.index - 40), m.index + 40), `${a.slug} ${re}`).toBeNull();
      }
    }
  });

  it('says each brand claim at most once on a page, and leaves the call to action’s lines to the call to action', () => {
    const claims = ['100% private. Your data is yours.', 'Works offline.', 'Instant.', '4x faster than typing.', 'Works in every app', 'Meetings, transcribed on your Mac'];
    for (const a of ARTICLES) {
      const t = html(a);
      for (const c of claims) expect(t.split(c).length - 1, `${a.slug}: ${c}`).toBeLessThanOrEqual(1);
      for (const c of CTA_CLAIMS) expect(t, `${a.slug}: ${c}`).not.toContain(c.replace(/\.$/, ''));
    }
  });

  it('names no shepetal price while the new price lines are pending, and never the retired line', () => {
    expect(APPS.shepetal.price).not.toMatch(/\d|\$/);
    for (const a of ARTICLES) {
      expect(text(a), a.slug).not.toMatch(/\$4\.99|yours forever|\$23\.99|\$0\.99/i);
    }
    expect(CTA_CLAIMS.join(' ')).not.toMatch(/\$|forever/i);
  });

  it('writes the name in lowercase and never with the š, which belongs to the one line on the landing page', () => {
    for (const a of ARTICLES) {
      expect(text(a), a.slug).not.toMatch(/Shepetal|SHEPETAL|š/);
    }
  });

  it('names no speech recognition or AI model, for shepetal or anyone else', () => {
    for (const a of ARTICLES) {
      const t = text(a);
      expect(t, a.slug).not.toMatch(
        /\b(Whisper|Parakeet|FluidAudio|OpenAI|GPT|ChatGPT|Llama|Gemini|Claude|Qwen|Moonshine|Canary|NeMo|wav2vec|Deepgram|AssemblyAI|ElevenLabs|Mistral|Voxtral|Apple Intelligence)\b/,
      );
      expect(t, a.slug).not.toMatch(/\bAI\b|\bLLMs?\b|\bmodels?\b|\bneural\b/);
    }
  });

  it('links each app it names to the app’s own site exactly once, and links nowhere else outside the site', () => {
    const urls = new Map(Object.values(APPS).map((app) => [app.url, app.id]));
    for (const a of ARTICLES) {
      const out = hrefs(a).filter((h) => /^https?:/.test(h));
      for (const id of a.apps.filter((x) => x !== 'shepetal')) {
        expect(out.filter((h) => h === APPS[id].url).length, `${a.slug} links ${id}`).toBe(1);
      }
      for (const h of out) expect(urls.has(h), `${a.slug}: ${h}`).toBe(true);
      expect(a.apps, a.slug).toContain('shepetal');
    }
  });

  it('links to other articles and to the landing page, and every internal link leads to a page that exists', () => {
    for (const a of ARTICLES) {
      const inner = hrefs(a).filter((h) => h.startsWith('/'));
      const toArticles = inner.filter((h) => h.startsWith('/blog/'));
      expect(new Set(toArticles).size, a.slug).toBeGreaterThanOrEqual(2);
      for (const h of toArticles) expect(bySlug(h.slice(6).split('#')[0]), h).toBeDefined();
      expect(inner.some((h) => h === '/' || h.startsWith('/#') || h === '/download'), a.slug).toBe(true);
      for (const r of a.related) expect(bySlug(r), `${a.slug} related ${r}`).toBeDefined();
      expect(a.related).not.toContain(a.slug);
    }
  });

  it('keeps one h1 per page (the title) and h2 sections with unique ids', () => {
    for (const a of ARTICLES) {
      expect(html(a), a.slug).not.toMatch(/<h1/);
      const ids = a.sections.map((s) => s.id);
      expect(new Set(ids).size, a.slug).toBe(ids.length);
      expect(ids, a.slug).not.toContain('questions');
    }
  });

  it('ranks shepetal first among the local apps, on device, offline, private and price', () => {
    const local = bySlug('best-local-dictation-apps')!;
    expect(local.ranked?.[0]).toBe('shepetal');
    for (const id of local.ranked ?? []) expect(APPS[id].offline.toLowerCase(), id).not.toMatch(/^no/);
  });

  it('describes every ranked app it ranks, and ranks each app once', () => {
    for (const a of ARTICLES.filter((x) => x.ranked)) {
      const h = html(a);
      for (const [i, id] of a.ranked!.entries()) expect(h, `${a.slug} ${id}`).toContain(`id="${i + 1}-${id}"`);
      expect(new Set(a.ranked).size).toBe(a.ranked!.length);
    }
  });

  it('has a link preview image for every article and the index', () => {
    for (const s of [...ARTICLES.map((a) => a.slug), 'blog']) {
      expect(existsSync(join(WEB, 'public', 'blog', 'og', `${s}.jpg`)), s).toBe(true);
    }
  });
});

describe('structured data', () => {
  it('describes each article, its breadcrumb and its questions, with absolute URLs', () => {
    for (const a of ARTICLES) {
      const ld = articleJsonLd(a);
      const types = ld['@graph'].map((n) => n['@type']);
      expect(types).toContain('Article');
      expect(types).toContain('BreadcrumbList');
      if (a.faq.length) expect(types).toContain('FAQPage');
      if (a.ranked) expect(types).toContain('ItemList');
      const json = JSON.stringify(ld);
      for (const u of json.match(/"(url|item|image|mainEntityOfPage)":"[^"]+"/g) ?? []) {
        if (!u.includes(SITE)) expect(u, a.slug).toMatch(/"(url)":"https:\/\//);
      }
      expect(json).not.toMatch(/<\/script/i);
    }
  });
});

describe('sitemap and robots', () => {
  it('lists the home page, the legal pages, the blog and every article', () => {
    const urls = sitemap().map((e) => e.url);
    for (const p of ['', '/privacy', '/terms', '/blog', ...ARTICLES.map((a) => `/blog/${a.slug}`)]) expect(urls).toContain(`${SITE}${p}`);
    expect(urls.some((u) => /\/(account|api|app|download)\b/.test(u))).toBe(false);
  });

  it('keeps crawlers out of the API, the app sign-in and the account, and points them at the sitemap', () => {
    const r = robots();
    const rules = Array.isArray(r.rules) ? r.rules[0] : r.rules;
    expect(rules.disallow).toEqual(expect.arrayContaining(['/api/', '/app/', '/account']));
    expect(r.sitemap).toBe(`${SITE}/sitemap.xml`);
  });
});

describe('blog pages', () => {
  it('inline their styles minified and whole: balanced braces, no comments, only the brand tokens', () => {
    expect(BLOG_CSS.split('{').length).toBe(BLOG_CSS.split('}').length);
    expect(BLOG_CSS).not.toContain('/*');
    expect(BLOG_CSS).toContain('.bl-cta{');
    expect(BLOG_CSS).toContain('@media (max-width: 719px){');
    for (const v of BLOG_CSS.match(/var\(--[a-z0-9-]+/g) ?? []) expect(v, v).toMatch(/var\(--(sh|bl)-/);
    expect(BLOG_CSS.length).toBeLessThan(10_000);
  });

  it('render statically: no request-time APIs, and unknown slugs are a 404', () => {
    const page = readFileSync(join(WEB, 'src', 'app', '(site)', 'blog', '[slug]', 'page.tsx'), 'utf8');
    expect(page).toContain('generateStaticParams');
    expect(page).toContain('notFound()');
    // dynamicParams = false 404s every article on the Worker (OpenNext with no incremental cache): keep it out.
    expect(page).not.toMatch(/export const dynamicParams = false/);
    expect(page).not.toMatch(/cookies\(|headers\(|auth\(/);
  });
});
