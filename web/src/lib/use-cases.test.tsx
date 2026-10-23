import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import sitemap from '@/app/sitemap';
import { SiteFooter } from '@/components/site/Shell';
import { UseCasePage } from '@/components/site/UseCase';
import { TRY as STORY_TRY } from '@/components/story/Story';
import { SITE_URL } from './site';
import { CLAIMS, TRY, USE_CASE_OG, USE_CASES, useCaseMetadata } from './use-cases';

const WEB = join(__dirname, '..', '..');
const FOR = join(WEB, 'src', 'app', '(site)', 'for');
const SLUGS = ['developers', 'writers', 'rsi', 'adhd', 'privacy', 'meetings'];

const html = (slug: string) => renderToStaticMarkup(<UseCasePage slug={slug} />);
const text = (markup: string) =>
  markup
    .replace(/<script[\s\S]*?<\/script>/g, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&#x27;|&#39;/g, "'")
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/\s+/g, ' ');
/** What a reader sees: the page text, the metadata and the link preview. */
const words = (slug: string) => {
  const u = USE_CASES.find((x) => x.slug === slug)!;
  const og = USE_CASE_OG[`for-${slug}`];
  const img = (useCaseMetadata(slug).openGraph?.images as { alt: string }[])[0];
  return `${text(html(slug))} ${u.title} ${u.description} ${u.label} ${og.title} ${og.sub} ${img.alt}`;
};

/**
 * The brand voice (Pavel's rules for brand copy), as checks on plain text. Each returns what it found, so a failure
 * names the line. The banned lines and their variants, the hedges, a capital "Shepetal", the em dash, a model name.
 */
const VOICE: [string, RegExp][] = [
  ['banned line: hold fn, speak, let go', /\bhold(ing)? (down )?(the )?(fn|key|🌐|globe)\b|\blet go\b|\bfn,? (speak|talk)\b|\b(speak|talk), let go/i],
  ['banned line: dictation that keeps quiet', /keeps? quiet/i],
  ['hedge', /\b(about|around|roughly|up to|typically|may|might|maybe|perhaps|could|probably|likely|approximately|nearly|almost|usually|generally)\b/i],
  ['capital Shepetal', /\b(?!shepetal\b)[Ss][Hh][Ee][Pp][Ee][Tt][Aa][Ll]\b|Šepetal|šepetal/],
  ['em dash', /\u2014|\u2013|&mdash;|&ndash;|\s--\s/],
  ['AI or model name', /\bA\.?I\b|artificial intelligence|machine learning|neural|\bLLM\b|\bmodels?\b|whisper|parakeet|nvidia|openai|\bgpt|chatgpt|llama|qwen|gemma|mistral|canary|wav2vec|vosk|deepgram|gemini|claude|anthropic|copilot|hugging ?face/i],
  ['other product', /wispr|superwhisper|dragon|otter|macwhisper|siri|apple dictation|voice ?control|talon|aqua voice|zoom|teams|google|meet\b|slack|git[h]ub|gitlab|vs ?code|xcode|notion|obsidian|ms word|google docs|gmail/i],
  ['footnote', /[\u00b9\u00b2\u00b3\u2070-\u2079*†‡]/],
];
const voice = (t: string) => VOICE.filter(([, re]) => re.test(t)).map(([name, re]) => `${name}: "${t.match(re)?.[0]}"`);

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

  it('each have a canonical on shepetal.app, their own title, description and link preview', () => {
    const titles = new Set<string>();
    for (const slug of SLUGS) {
      const m = useCaseMetadata(slug);
      expect(new URL(String(m.alternates?.canonical), SITE_URL).href).toBe(`https://shepetal.app/for/${slug}`);
      expect(m.openGraph?.url).toBe(`/for/${slug}`);
      const img = (m.openGraph?.images as { url: string }[])[0];
      expect(img.url).toBe(`/og/for-${slug}.jpg`);
      expect(existsSync(join(WEB, 'public', img.url))).toBe(true);
      expect((m.twitter?.images as { url: string }[])[0].url).toBe(img.url);
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

  it('the voice checks catch every rule they stand for', () => {
    const bad: Record<string, string> = {
      'banned line: hold fn, speak, let go': 'Hold fn, speak, let go.',
      'banned line: dictation that keeps quiet': 'Dictation that keeps quiet.',
      hedge: 'It takes about a second.',
      'capital Shepetal': 'Shepetal works in every app.',
      'em dash': 'Instant \u2014 and private.',
      'AI or model name': 'Powered by AI.',
      'other product': 'Like Wispr, but private.',
      footnote: 'Instant.\u00b9',
    };
    expect(Object.keys(bad).sort()).toEqual(VOICE.map(([n]) => n).sort());
    for (const [name, line] of Object.entries(bad)) expect(voice(line), line).toEqual([`${name}: "${line.match(VOICE.find(([n]) => n === name)![1])![0]}"`]);
    for (const line of ['hold fn, talk', 'Hold the key and speak.', 'It might help.', 'up to 4x', 'SHEPETAL', 'Parakeet inside', 'a Whisper model', 'Instant -- private']) expect(voice(line), line).not.toEqual([]);
    for (const line of ['shepetal works in every app.', 'Press one key. Your words appear wherever your cursor is.']) expect(voice(line), line).toEqual([]);
  });

  it('keep the voice: no banned line, hedge, capital Shepetal, em dash, model name, other product or footnote', () => {
    for (const slug of SLUGS) expect(voice(words(slug)), slug).toEqual([]);
    // the "Compare" list names the other products by design; compare.test.tsx checks it
    const footer = renderToStaticMarkup(<SiteFooter />).replace(/<nav aria-label="Compare"[\s\S]*?<\/nav>/, ' ');
    expect(voice(text(footer)), 'footer').toEqual([]);
  });

  it('keep Pavel’s voice: plain headings, second person, no contrasts or tails, no short sentence closing a paragraph', () => {
    // the pavel-voice checks: "not a", "rather than", "never" and the rest are said as what happens instead
    const TELLS = /\bnot an?\b|rather than|instead of|does not|doesn['’]t|has no|\bnever\b|on purpose|intentional|for the record|\bwithout\b|at the time of writing|nothing else|\bno\b/i;
    const sentences = (p: string) => p.split(/(?<=[.:?])\s+(?=[A-Za-z])/).filter(Boolean);
    const short = (x: string) => x.split(/\s+/).length < 8;
    for (const u of USE_CASES) {
      expect(u.lede, u.slug).toMatch(/\byou(r)?\b/i);
      for (const s of u.scenarios) expect(s.title.split(/\s+/).length, `${u.slug}: ${s.title}`).toBeLessThanOrEqual(3);
      // the health pages' note is the one line that says what shepetal is not, and the test above pins it
      const paragraphs = [u.lede, u.description, ...u.scenarios.map((s) => s.text), (u.note ?? '').replace(/^shepetal is a dictation app, not a medical device\.\s*/, '')].filter(Boolean);
      for (const p of paragraphs) {
        expect(p.match(TELLS)?.[0], `${u.slug}: ${p}`).toBeUndefined();
        const ss = sentences(p.replace(/(100% private\. Your data is yours\.|Meetings, transcribed on your Mac\.)/g, ''));
        if (ss.length > 1 || p === u.lede) expect(short(ss[ss.length - 1]), `${u.slug} ends short: ${p}`).toBe(false);
        for (let i = 1; i < ss.length; i++) expect(short(ss[i - 1]) && short(ss[i]), `${u.slug} two short: ${p}`).toBe(false);
      }
    }
    const page = text(renderToStaticMarkup(<UseCasePage slug="developers" />));
    expect(page).not.toMatch(TELLS);
  });

  it('keep the voice: no exclamation, no medical promise, no steps or requirements', () => {
    for (const slug of SLUGS) {
      const t = words(slug);
      expect(t, slug).not.toContain('!');
      expect(t, slug).not.toMatch(/Meeting reminder|Meeting detected/);
      expect(t, slug).not.toMatch(/\b(cure|heal|relie|therap|treat|symptom|pain-free|prevent|diagnos|recover|clinical|proven|focus better|concentrat|improve|reduce|helps? (with|you))/i);
      // how it works and what it needs: the FAQ and the Privacy Policy, not marketing copy
      expect(t, slug).not.toMatch(/macOS|Apple silicon|Intel|sign in|license|once a (day|week)|\bMB\b|download|install|settings|permission/i);
      expect(t, slug).not.toMatch(/git[h]ub\.com|backant\.io/i);
    }
  });

  it('the health pages say what the app is and promise nothing', () => {
    for (const slug of ['rsi', 'adhd']) expect(USE_CASES.find((u) => u.slug === slug)!.note).toMatch(/^shepetal is a dictation app, not a medical device\./);
  });

  it('publish no number but the trial, the two prices, the 25 languages and the approved claims', () => {
    const allowed = new Set(['30', '23.99', '0.99', '25', '100%', '4x']);
    for (const slug of SLUGS) {
      const t = words(slug);
      for (const n of t.match(/\d[\d.,]*(%|x\b)?/g) ?? []) expect(allowed.has(n.replace(/[.,]$/, '')), `${slug}: ${n}`).toBe(true);
      // the claims only word for word
      for (const m of t.match(/100%[^.]*\./g) ?? []) expect(m).toBe('100% private.');
      expect(t.match(/100% private\. \S+ \S+ \S+\./g)?.every((m) => m === '100% private. Your data is yours.') ?? true).toBe(true);
      for (const m of t.match(/\S*4x[^.]*\./g) ?? []) expect(m).toBe('4x faster than typing.');
      // the prices exactly as on the landing page
      expect(t).toContain('$23.99 once. Yours forever.');
      expect(t).toContain('$0.99 a month.');
      expect(t.match(/\$[\d.]+[^.]*\./g)?.every((m) => m === '$23.99 once.' || m === '$0.99 a month.')).toBe(true);
    }
  });

  it('list only the approved claims under "The facts", one per line, word for word', () => {
    for (const u of USE_CASES) {
      expect(u.facts.length, u.slug).toBeGreaterThan(0);
      for (const f of u.facts) expect(CLAIMS as readonly string[], `${u.slug}: ${f}`).toContain(f);
      expect(new Set(u.facts).size).toBe(u.facts.length);
      const list = html(u.slug).match(/<h2>The facts<\/h2><ul>([\s\S]*?)<\/ul>/)?.[1] ?? '';
      expect(list).toBe(u.facts.map((f) => `<li>${f}</li>`).join(''));
    }
  });

  it('carry no price and no steps on a link preview', () => {
    for (const slug of SLUGS) {
      const og = USE_CASE_OG[`for-${slug}`];
      expect(og.path).toBe(`/for/${slug}`);
      expect(`${og.title} ${og.sub}`).not.toMatch(/\$|free|price|month|press|click|choose/i);
    }
    expect(Object.keys(USE_CASE_OG)).toEqual(SLUGS.map((s) => `for-${s}`));
  });

  it('send no structured data of their own (the FAQ page carries the FAQ)', () => {
    for (const slug of SLUGS) expect(html(slug)).not.toContain('application/ld+json');
  });

  it('have no prefetching link and nothing from another host', () => {
    for (const slug of SLUGS) {
      const h = html(slug) + renderToStaticMarkup(<SiteFooter />);
      expect(h, slug).not.toMatch(/(src|href)="(https?:)?\/\//);
    }
    for (const f of [join(WEB, 'src', 'components', 'site', 'UseCase.tsx'), join(WEB, 'src', 'components', 'site', 'Shell.tsx')]) {
      const src = readFileSync(f, 'utf8');
      for (const tag of src.match(/<Link\b[^>]*>/g) ?? []) expect(tag, f).toContain('prefetch={false}');
    }
  });

  it('are linked from the site footer’s "Made for" list', () => {
    const f = renderToStaticMarkup(<SiteFooter />);
    const nav = f.match(/<nav aria-label="Made for"[\s\S]*?<\/nav>/)?.[0] ?? '';
    expect(nav.match(/href="[^"]+"/g)).toEqual(SLUGS.map((s) => `href="/for/${s}"`));
    expect(nav).toContain('Made for');
  });
});
