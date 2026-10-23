import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { renderToStaticMarkup } from 'react-dom/server';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { copyProblems, visibleText } from '@/lib/brand-copy';
import { CONSENT_TEXT, PAGE } from '@/lib/waitlist-config';
import { WaitlistForm } from './Waitlist';

vi.mock('next/navigation', () => ({
  notFound: () => {
    throw new Error('NEXT_NOT_FOUND');
  },
}));
afterEach(() => vi.unstubAllEnvs());

const APP = join(__dirname, '..', '..', 'app');
const DIR = join(APP, '(site)', 'waitlist');
const read = (p: string) => readFileSync(join(DIR, p, 'page.tsx'), 'utf8');
/** The attributes of the first tag that has all of `has`, in any order (React picks the order). */
const attrs = (html: string, name: string, ...has: string[]) => {
  const tag = [...html.matchAll(new RegExp(`<${name}\\b[^>]*>`, 'g'))].map((m) => m[0]).find((t) => has.every((h) => t.includes(h)));
  return tag ? Object.fromEntries([...tag.matchAll(/(\w+)="([^"]*)"/g)].map((m) => [m[1], m[2]])) : null;
};

// The build inlines WAITLIST from wrangler.toml (next.config.ts): what the site shows with it "off".
describe('with WAITLIST off', () => {
  beforeEach(() => {
    vi.stubEnv('WAITLIST', 'off');
    // The FAQ's answers are built when the module loads (as in the build, which inlines WAITLIST).
    vi.resetModules();
  });
  const render = async (file: string) => {
    const mod = await import(/* @vite-ignore */ join(APP, file));
    return renderToStaticMarkup(mod.default());
  };

  it('the form renders nothing', () => {
    expect(process.env.WAITLIST).toBe('off');
    expect(renderToStaticMarkup(<WaitlistForm />)).toBe('');
  });

  it('the pages that take an address or follow a signup are the 404 page', async () => {
    for (const p of ['', 'thanks', 'check', 'confirmed']) await expect(render(join('(site)', 'waitlist', p, 'page.tsx')), p).rejects.toThrow('NEXT_NOT_FOUND');
    // What a link already sent leads to still works.
    expect(await render(join('(site)', 'waitlist', 'unsubscribe', 'page.tsx'))).toContain('action="/api/waitlist/unsubscribe"');
    expect(await render(join('(site)', 'waitlist', 'link', 'page.tsx'))).not.toContain('href="/waitlist"');
  });

  it('nothing links to it, the sitemap leaves it out, and the privacy policy does not describe it', async () => {
    expect(await render(join('(site)', 'faq', 'page.tsx'))).not.toMatch(/waitlist/i);
    const sitemap = (await import('@/app/sitemap')).default();
    expect(sitemap.map((e) => e.url).join(' ')).not.toContain('/waitlist');
    expect(sitemap.length).toBeGreaterThan(5);
    expect(await render(join('(site)', 'privacy', 'page.tsx'))).not.toMatch(/waitlist/i);
  });
});

describe('with WAITLIST on', () => {
  it('the FAQ links to it, the sitemap has it, and the privacy policy has its section', async () => {
    vi.stubEnv('WAITLIST', 'on');
    // The FAQ's answers are built when the module loads (as in the build, which inlines WAITLIST).
    vi.resetModules();
    const faq = renderToStaticMarkup((await import(/* @vite-ignore */ join(APP, '(site)', 'faq', 'page.tsx'))).default());
    expect(faq).toContain('<a href="/waitlist">Join the waitlist</a> and we will email you when yours is out.');
    expect((await import('@/app/sitemap')).default().map((e) => e.url)).toContain(`https://${process.env.SHEPETAL_DOMAIN}/waitlist`);
    const privacy = renderToStaticMarkup((await import(/* @vite-ignore */ join(APP, '(site)', 'privacy', 'page.tsx'))).default());
    for (const must of ['id="waitlist"', 'one purpose only', 'double opt-in', 'Art. 6(1)(a) GDPR', 'withdraw', 'deletes your address at once', 'within 30 days', 'and the waitlist emails'])
      expect(privacy, must).toContain(must);
    // The trial emails are III.8, so the waitlist is III.9.
    expect(privacy).toContain('<h3 id="trial-emails">8. Emails about your trial</h3>');
    expect(privacy).toContain('<h3 id="waitlist">9. The waitlist</h3>');
    expect(privacy).toContain('and the emails about your trial (section III.8), and the waitlist emails (section III.9).');
    const flat = privacy.replace(/\s+/g, ' ');
    for (const must of [
      'Legal basis: Art. 6(1)(f) GDPR, our legitimate interest in direct marketing for our own product to people who started a trial.',
      'You can object to these emails at any time, free of charge and without giving reasons, through the unsubscribe link in every one of them',
      'For the emails about your trial (section 8), object at any time, free of charge and without giving reasons',
      'sections 1, 2, 4, 5, 6, 7 and 8 above',
      'Emails about your trial: the record of which emails we sent',
    ])
      expect(flat, must).toContain(must);
    expect(flat).not.toMatch(/checkbox|tick the box|ticked the box/);
    expect(renderToStaticMarkup((await import(/* @vite-ignore */ join(APP, '(site)', 'waitlist', 'page.tsx'))).default())).toContain(
      'We only use your email to tell you when shepetal comes to a platform you chose.',
    );
  });
});

describe('the waitlist form', () => {
  vi.stubEnv('WAITLIST', 'on');
  const html = renderToStaticMarkup(<WaitlistForm />);
  vi.unstubAllEnvs();

  // No script runs it: a plain POST that worker.ts answers with a redirect.
  it('is a plain form POST to /api/waitlist, and works without JavaScript', () => {
    expect(attrs(html, 'form')).toEqual({ class: 's-wl', action: '/api/waitlist', method: 'post' });
    expect(attrs(html, 'input', 'name="email"')).toMatchObject({ type: 'email', required: '', maxLength: '254' });
    expect(html).not.toMatch(/<script|onSubmit|onClick/i);
    expect(html.match(/<button\b/g)).toHaveLength(1);
  });

  it('offers Windows, Linux and iPhone, any number of them', () => {
    expect([...html.matchAll(/type="checkbox" name="platform" value="(\w+)"/g)].map((m) => m[1])).toEqual(['windows', 'linux', 'iphone']);
    expect(html.replace(/<[^>]+>/g, ' ')).toMatch(/Windows\s+Linux\s+iPhone/);
  });

  // GDPR consent is a box the person ticks, in these exact words, which each row stores (consent_text).
  it('asks for consent with a required box that starts unticked, in the words the database stores', () => {
    expect(CONSENT_TEXT).toBe('Email me when shepetal comes to a platform I chose. You use my email for this only, and I can unsubscribe anytime.');
    expect(attrs(html, 'input', 'name="consent"')).toEqual({ type: 'checkbox', required: '', name: 'consent', value: 'yes' });
    expect(html).toMatch(new RegExp(`<label class="s-check"><input [^>]*name="consent"[^>]*/>${CONSENT_TEXT.replace(/\./g, '\\.')}</label>`));
    expect(html).not.toMatch(/checked/);
  });
});

describe('the waitlist pages', () => {
  const pages = ['', ...readdirSync(DIR, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name)];

  // The Workers Free plan gives a request 10 ms of CPU, and a React render takes more: every waitlist page is
  // prerendered and served from the cache (worker.ts). force-static makes the build fail if one reads the request.
  it('are all prerendered: force-static, and none reads the query, cookies, headers or the session', () => {
    expect(pages.sort()).toEqual(['', ...Object.values(PAGE).map((p) => p.slice('/waitlist/'.length))].sort());
    for (const p of pages) {
      const src = read(p);
      expect(src, p || 'waitlist').toContain("export const dynamic = 'force-static';");
      expect(src, p).not.toMatch(/searchParams|cookies\(|headers\(|@\/lib\/auth|getCloudflareContext/);
    }
    // After a build, Next's own list of prerendered routes has them all (with WAITLIST off, those left are the
    // unsubscribe pages: the rest are built as the 404 page).
    const manifest = join(__dirname, '..', '..', '..', '.next', 'prerender-manifest.json');
    if (existsSync(manifest)) {
      const routes = Object.keys(JSON.parse(readFileSync(manifest, 'utf8')).routes);
      for (const p of ['unsubscribe', 'unsubscribed', 'link']) expect(routes).toContain(`/waitlist/${p}`);
    }
  });

  it('send the unsubscribe button to the POST, with the field worker.ts fills from the link', () => {
    const src = read('unsubscribe');
    expect(src).toContain('<form className="s-wl" method="post" action="/api/waitlist/unsubscribe">');
    expect(src).toContain('<input type="hidden" name="t" value="" />');
  });

  it('keep the voice: lowercase shepetal, no hedges, no dates', () => {
    for (const p of pages) {
      const text = read(p).replace(/^(import|export const|\/\*\*| \*).*$/gm, '').replace(/<[^>]+>/g, ' ');
      expect(text, p).not.toMatch(/Shepetal|\b(may|might|soon|perhaps|hopefully)\b|20\d\d|Q[1-4]\b/);
    }
  });

  it('link with prefetch off', () => {
    for (const p of pages) for (const tag of read(p).match(/<Link\b[^>]*>/g) ?? []) expect(tag, p).toContain('prefetch={false}');
  });
});

// Every word a visitor reads on the waitlist: the pages, their titles and previews, the form, the FAQ line and the
// privacy section (the email is checked in src/lib/waitlist.test.ts). Brand rules and the voice skill's sentence shapes.
describe('the waitlist copy', () => {
  it('catches what the brand rules ban', () => {
    for (const bad of ['Shepetal is out.', 'Hold fn, speak, let go.', 'hold fn, talk', 'Dictation that keeps quiet.', 'It may come.', 'up to 3 years', 'Now with AI.', 'That is it—done.', 'Twice the speed<sup>1</sup>', '3x faster than typing', 'We never sell it.', 'It works without a key.', '$5 a month'])
      expect(copyProblems(bad), bad).not.toEqual([]);
    for (const good of ['$23.99 once. Yours forever.', '$0.99 a month.', '4x faster than typing.', 'Works offline.'])
      expect(copyProblems(good), good).toEqual([]);
  });

  it('keeps every brand rule on every page, title, preview, label and message', async () => {
    vi.stubEnv('WAITLIST', 'on');
    vi.resetModules();
    const texts: Record<string, string> = {};
    const pages = ['', ...readdirSync(DIR, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name)];
    for (const p of pages) {
      const mod = await import(/* @vite-ignore */ join(DIR, p, 'page.tsx'));
      const html = renderToStaticMarkup(mod.default());
      expect(html, p).not.toBe('');
      texts[p || 'waitlist'] = visibleText(html);
      const m = mod.metadata as { title?: string; description?: string; openGraph?: { title?: string; description?: string; images?: { alt?: string }[] } };
      texts[`${p || 'waitlist'} metadata`] = [m.title, m.description, m.openGraph?.title, m.openGraph?.description, m.openGraph?.images?.[0]?.alt].join(' ');
    }
    const { PAGES } = await import('@/lib/seo');
    texts['link preview'] = `${PAGES.waitlist.title} ${PAGES.waitlist.sub}`;
    texts.consent = CONSENT_TEXT;
    const faq = visibleText(renderToStaticMarkup((await import(/* @vite-ignore */ join(APP, '(site)', 'faq', 'page.tsx'))).default()));
    texts.faq = faq.match(/Join the waitlist[^.]*\./)![0];
    const privacy = renderToStaticMarkup((await import(/* @vite-ignore */ join(APP, '(site)', 'privacy', 'page.tsx'))).default());
    texts.privacy = [
      privacy.match(/<h3 id="waitlist">[\s\S]*?(?=<div class="s-box">)/)![0],
      privacy.match(/<li>The waitlist:[^<]*<\/li>/)![0],
      privacy.match(/The waitlist needs[^.]*\./)![0],
      privacy.match(/and the waitlist emails \(section III\.9\)/)![0],
    ].map(visibleText).join(' ');
    for (const [where, text] of Object.entries(texts)) expect(copyProblems(text), `${where}: ${text}`).toEqual([]);
    expect(texts.privacy).toContain('one purpose only');
  });
});
