import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { CONSENT_TEXT, PAGE } from '@/lib/waitlist';
import { WaitlistForm } from './Waitlist';

const APP = join(__dirname, '..', '..', 'app');
const DIR = join(APP, '(site)', 'waitlist');
const read = (p: string) => readFileSync(join(DIR, p, 'page.tsx'), 'utf8');
/** The attributes of the first tag that has all of `has`, in any order (React picks the order). */
const attrs = (html: string, name: string, ...has: string[]) => {
  const tag = [...html.matchAll(new RegExp(`<${name}\\b[^>]*>`, 'g'))].map((m) => m[0]).find((t) => has.every((h) => t.includes(h)));
  return tag ? Object.fromEntries([...tag.matchAll(/(\w+)="([^"]*)"/g)].map((m) => [m[1], m[2]])) : null;
};

describe('the waitlist form', () => {
  const html = renderToStaticMarkup(<WaitlistForm />);

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
    expect(CONSENT_TEXT).toBe('Email me when shepetal comes to my platform. Unsubscribe anytime.');
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
    // After a build, Next's own list of prerendered routes has them all.
    const manifest = join(__dirname, '..', '..', '..', '.next', 'prerender-manifest.json');
    if (existsSync(manifest)) {
      const routes = Object.keys(JSON.parse(readFileSync(manifest, 'utf8')).routes);
      for (const p of pages) expect(routes).toContain(p ? `/waitlist/${p}` : '/waitlist');
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

  it('are linked from the FAQ answer about other platforms', () => {
    const faq = readFileSync(join(APP, '(site)', 'faq', 'page.tsx'), 'utf8');
    expect(faq).toMatch(/Is there shepetal for Windows, Linux or iPhone\?[\s\S]{0,400}<Link href="\/waitlist">Join the waitlist<\/Link>/);
  });
});
