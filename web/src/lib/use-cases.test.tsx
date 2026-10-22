import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import sitemap from '@/app/sitemap';
import { SiteFooter } from '@/components/site/Shell';
import { UseCasePage } from '@/components/site/UseCase';
import { TRY as STORY_TRY } from '@/components/story/Story';
import { SITE_URL } from './site';
import { TRY, USE_CASES, useCaseFaqJsonLd, useCaseMetadata } from './use-cases';

const WEB = join(__dirname, '..', '..');
const FOR = join(WEB, 'src', 'app', '(site)', 'for');
const SLUGS = ['developers', 'writers', 'rsi', 'adhd', 'privacy', 'meetings'];

const html = (slug: string) => renderToStaticMarkup(<UseCasePage slug={slug} />);
/** What a reader sees: the page text, the metadata and the FAQ data. */
const words = (slug: string) => {
  const u = USE_CASES.find((x) => x.slug === slug)!;
  const page = html(slug)
    .replace(/<script[\s\S]*?<\/script>/g, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&#x27;|&#39;/g, "'")
    .replace(/&amp;/g, '&')
    .replace(/\s+/g, ' ');
  return `${page} ${u.title} ${u.description} ${u.label} ${JSON.stringify(useCaseFaqJsonLd(slug) ?? '')}`;
};

describe('use-case pages', () => {
  it('are the six audiences, each with its own page file', () => {
    expect(USE_CASES.map((u) => u.slug)).toEqual(SLUGS);
    expect(readdirSync(FOR).sort()).toEqual([...SLUGS].sort());
  });

  it('are prerendered: static pages with no request data, no sign-in and nothing dynamic', () => {
    for (const slug of SLUGS) {
      const src = readFileSync(join(FOR, slug, 'page.tsx'), 'utf8');
      expect(src, slug).toContain("export const dynamic = 'error';");
      expect(src, slug).toContain(`<UseCasePage slug="${slug}" />`);
      expect(src, slug).toContain(`useCaseMetadata('${slug}')`);
    }
    for (const f of [join(WEB, 'src', 'components', 'site', 'UseCase.tsx'), join(WEB, 'src', 'lib', 'use-cases.ts'), ...SLUGS.map((s) => join(FOR, s, 'page.tsx'))]) {
      const src = readFileSync(f, 'utf8');
      expect(src, f).not.toMatch(/searchParams|\bauth\(|@\/lib\/auth|next\/headers|cookies\(|headers\(|force-dynamic|revalidate|'use cache'|@\/lib\/db|getCloudflareContext|async function/);
    }
  });

  it('are in the sitemap on the domain', () => {
    const urls = sitemap().map((e) => e.url);
    for (const slug of SLUGS) expect(urls).toContain(`https://shepetal.app/for/${slug}`.replace('https://shepetal.app', SITE_URL));
    expect(SITE_URL).toBe('https://shepetal.app');
  });

  it('each have a canonical on shepetal.app, their own title and description, and the landing page’s link preview', () => {
    const titles = new Set<string>();
    for (const slug of SLUGS) {
      const m = useCaseMetadata(slug);
      expect(new URL(String(m.alternates?.canonical), SITE_URL).href).toBe(`https://shepetal.app/for/${slug}`);
      expect(m.openGraph?.url).toBe(`/for/${slug}`);
      const img = (m.openGraph?.images as { url: string }[])[0];
      expect(img.url).toBe('/og/home.jpg');
      expect(existsSync(join(WEB, 'public', img.url))).toBe(true);
      expect(String(m.description).length).toBeGreaterThan(50);
      expect(String(m.description).length).toBeLessThanOrEqual(160);
      titles.add(String(m.title));
    }
    expect(titles.size).toBe(SLUGS.length);
  });

  it('each have one H1, a lede, three or four scenarios, and the trial button to /install?ref=for-<slug>', () => {
    expect(TRY).toBe(STORY_TRY);
    for (const slug of SLUGS) {
      const h = html(slug);
      expect(h.match(/<h1\b/g), slug).toHaveLength(1);
      expect(h).toContain('class="s-lede"');
      const u = USE_CASES.find((x) => x.slug === slug)!;
      expect(u.scenarios.length).toBeGreaterThanOrEqual(3);
      expect(u.scenarios.length).toBeLessThanOrEqual(4);
      const ctas = [...h.matchAll(/<a class="s-btn s-btn-signal" href="([^"]+)">([^<]+)<\/a>/g)];
      expect(ctas.length, slug).toBeGreaterThan(0);
      for (const [, href, text] of ctas) {
        expect(href).toBe(`/install?ref=for-${slug}`);
        expect(text).toBe('Try 30 days free');
      }
      // the account and the FAQ stay links in the page; no other way out to /install or /download
      expect(h.match(/href="\/(install|download)[^"]*"/g)?.every((x) => x === `href="/install?ref=for-${slug}"`)).toBe(true);
    }
  });

  it('keep the voice: none of the banned lines, no model, no competitor, no hedge, no exclamation, no medical promise', () => {
    for (const slug of SLUGS) {
      const t = words(slug);
      expect(t, slug).not.toMatch(/hold (down )?(the )?fn|let go|keeps quiet/i);
      expect(t, slug).not.toMatch(/\bAI\b|artificial intelligence|neural|\bmodels?\b|whisper\b|parakeet|nvidia|openai|\bgpt|llama|canary|wav2vec|vosk|deepgram|gemini|claude/i);
      expect(t, slug).not.toMatch(/wispr|superwhisper|dragon|otter|macwhisper|siri|apple dictation|voice ?control|talon|aqua voice|zoom|teams|google meet/i);
      expect(t, slug).not.toMatch(/\b(may|might|maybe|perhaps|could|probably|likely|should)\b/i);
      expect(t, slug).not.toContain('!');
      expect(t, slug).not.toMatch(/Shepetal|SHEPETAL/);
      expect(t, slug).not.toMatch(/Meeting reminder/);
      expect(t, slug).not.toMatch(/\b(cure|heal|relie|therap|symptom|pain-free|prevent|diagnos|recover|clinical|proven|focus better)/i);
      expect(t, slug).not.toMatch(/git[h]ub\.com|backant\.io/i);
    }
  });

  it('publish no number but the trial, the two prices, macOS 14.4, the 25 languages and the landing page’s claims', () => {
    const allowed = new Set(['30', '23.99', '0.99', '14.4', '25', '100%', '4x']);
    for (const slug of SLUGS) {
      const t = words(slug);
      for (const n of t.match(/\d[\d.,]*(%|x\b)?/g) ?? []) expect(allowed.has(n.replace(/[.,]$/, '')), `${slug}: ${n}`).toBe(true);
      // the claims only word for word
      for (const m of t.match(/100%[^.]*\./g) ?? []) expect(m).toBe('100% private.');
      expect(t.match(/100% private\. \S+ \S+ \S+\./g)?.every((m) => m === '100% private. Your data is yours.') ?? true).toBe(true);
      for (const m of t.match(/4x[^.]*\./g) ?? []) expect(m).toBe('4x faster than typing.');
      expect(t.match(/(\S+) 4x faster/g)?.every((m) => m === 'Instant. 4x faster') ?? true).toBe(true);
      // the prices exactly as on the landing page
      expect(t).toContain('$23.99 once. Yours forever.');
      expect(t).toContain('$0.99 a month.');
      expect(t.match(/\$[\d.]+[^.]*\./g)?.every((m) => m === '$23.99 once.' || m === '$0.99 a month.')).toBe(true);
    }
  });

  it('send FAQ data only for questions the page shows and the FAQ answers', () => {
    const faq = readFileSync(join(WEB, 'src', 'app', '(site)', 'faq', 'page.tsx'), 'utf8');
    for (const u of USE_CASES) {
      const data = useCaseFaqJsonLd(u.slug);
      if (!u.qas?.length) {
        expect(data, u.slug).toBeNull();
        expect(html(u.slug)).not.toContain('application/ld+json');
        continue;
      }
      expect(data?.url).toBe(`${SITE_URL}/for/${u.slug}`);
      for (const x of u.qas) {
        expect(faq, x.q).toContain(`q: '${x.q}'`);
        expect(html(u.slug)).toContain(`<h2>${x.q}</h2>`);
      }
    }
  });

  it('are linked from the site footer’s "Made for" list', () => {
    const f = renderToStaticMarkup(<SiteFooter />);
    const nav = f.match(/<nav aria-label="Made for"[\s\S]*?<\/nav>/)?.[0] ?? '';
    expect(nav.match(/href="[^"]+"/g)).toEqual(SLUGS.map((s) => `href="/for/${s}"`));
    expect(nav).toContain('Made for');
  });
});
