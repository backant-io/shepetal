import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it, vi } from 'vitest';
import { safeNext } from '@/lib/next-path';

vi.mock('@/lib/auth', () => ({ signIn: async () => undefined }));
const { SignIn } = await import('./SignIn');

describe('sign-in page', () => {
  const html = renderToStaticMarkup(<SignIn />);

  it('has one clear action, Continue with Google, as the page’s only orange, in a real form', () => {
    expect(html).toContain('<h1 class="s-h1">Sign in.</h1>');
    expect(html.match(/s-btn-signal/g)).toHaveLength(1);
    expect(html).toMatch(
      /<form class="s-form"[^>]*><button type="submit" class="s-btn s-btn-signal">Continue with Google<\/button><\/form>/,
    );
    expect(html.match(/<button\b/g)).toHaveLength(1);
  });

  it('keeps the key small, beside the heading, and says what failed when Google sends the user back', () => {
    expect(html).toContain('class="s-key"');
    expect(html).toContain('class="kd-art"');
    expect(html).not.toContain('role="alert"');
    expect(renderToStaticMarkup(<SignIn failed />)).toContain('Sign-in did not finish. Try again.');
  });

  it('keeps the voice: lowercase shepetal, no hedges, no sign-in mechanics', () => {
    const text = html.replace(/<svg[\s\S]*?<\/svg>/g, '').replace(/<[^>]+>/g, ' ');
    expect(text).not.toMatch(/Shepetal|may|might|no card|only for the license/);
  });
});

describe('where a sign-in returns to', () => {
  it('stays on this site', () => {
    expect(safeNext('/account#plans')).toBe('/account#plans');
    expect(safeNext('/account?purchased=1')).toBe('/account?purchased=1');
    for (const bad of [undefined, null, '', 'https://evil.example/', '//evil.example/x', '/\\evil.example', 'account'])
      expect(safeNext(bad)).toBe('/account');
  });
});

describe('install help (the app is not notarized)', () => {
  it('gives the four steps in order: drag to Applications, Done, Open Anyway in Privacy & Security, once', async () => {
    const { InstallSteps } = await import('./InstallSteps');
    const text = renderToStaticMarkup(<InstallSteps />).replace(/<[^>]+>/g, ' ').replace(/&amp;/g, '&').replace(/\s+/g, ' ');
    let at = 0;
    for (const s of ['Drag shepetal into Applications.', 'click Done', 'System Settings, then Privacy & Security', 'Open Anyway', 'confirm with your password', 'You do this once.']) {
      const i = text.indexOf(s, at);
      expect(i, s).toBeGreaterThan(-1);
      at = i;
    }
    expect(renderToStaticMarkup(<InstallSteps />).match(/<li>/g)).toHaveLength(4);
  });

  it('is where the account’s Download button lands, and that page starts the download', () => {
    const read = (p: string) => readFileSync(join(__dirname, '..', '..', 'app', '(site)', p, 'page.tsx'), 'utf8');
    expect(read('account')).toContain('href={`/install${from}`}');
    const install = read('install');
    expect(install).toContain('<meta httpEquiv="refresh" content={`1;url=${download}`} />');
    // static: worker.ts adds ?ref= and utm_* to both /download links at the edge (edge.test.ts)
    expect(install).toContain("const download = '/download';");
    expect(install).not.toContain('searchParams');
    expect(install).toContain('<InstallSteps />');
    expect(install).toContain('href={download}');
  });
});

describe('footer', () => {
  it('reads Privacy · Terms · Refunds · Legal, on the landing page and on every other page', async () => {
    const { SiteFooter } = await import('./Shell');
    const links = (html: string) => [...html.matchAll(/<nav aria-label="Legal"[\s\S]*?<\/nav>/g)][0][0].match(/href="[^"]+"/g);
    const want = ['href="/privacy"', 'href="/terms"', 'href="/refunds"', 'href="/legal"'];
    expect(links(renderToStaticMarkup(<SiteFooter />))).toEqual(want);
    const { Story } = await import('@/components/story/Story');
    expect(links(renderToStaticMarkup(<Story />))).toEqual(want);
  });
});

describe('legal pages', () => {
  const page = (p: string) => readFileSync(join(__dirname, '..', '..', 'app', '(site)', p, 'page.tsx'), 'utf8');

  it('credit the fonts the site uses and keep the notices', () => {
    const legal = page('legal');
    for (const s of [
      '/fonts/licenses/Archivo-OFL.txt',
      '/fonts/licenses/BodoniModa-OFL.txt',
      '/fonts/licenses/FragmentMono-OFL.txt',
      '/brand/emoji/NOTICE.txt',
      '/brand/emoji/LICENSE-Apache-2.0.txt',
      'Mac and macOS are trademarks of Apple Inc.',
    ])
      expect(legal).toContain(s);
    for (const f of ['Archivo-OFL.txt', 'BodoniModa-OFL.txt', 'FragmentMono-OFL.txt'])
      expect(readFileSync(join(__dirname, '..', '..', '..', 'public', 'fonts', 'licenses', f), 'utf8')).toMatch(
        /SIL OPEN FONT LICENSE/i,
      );
  });

  it('have a legal notice that names the seller, linked from /legal', () => {
    const impressum = page('impressum');
    for (const p of ['BackAnt, Inc., a Delaware corporation', '131 Continental Dr, Suite 305', 'Newark, DE 19713', 'Pavel Hegler', 'file number 10279385', 'support@shepetal.app'])
      expect(impressum).toContain(p);
    expect(impressum).not.toMatch(/\[(COMPANY|ADDRESS|REPRESENTATIVE|REGISTRATION)\]/);
    expect(page('legal')).toContain('href="/impressum"');
  });

  it('have a refund policy that says what the terms and the payment code do', () => {
    const refunds = page('refunds').replace(/\s+/g, ' ');
    for (const s of ['30 days of shepetal, free', 'within 14 days of the purchase', '$23.99 once', '$0.99 a month', 'Cancel anytime', 'nothing is charged again', 'switch to the lifetime license'])
      expect(refunds).toContain(s);
    expect(page('terms').replace(/\s+/g, ' ')).toContain('within 14 days of a lifetime purchase for a full refund');
  });

  it('use the site’s header, type and prose', () => {
    for (const p of ['privacy', 'terms', 'legal', 'impressum', 'refunds']) {
      const src = page(p);
      expect(src).toContain('<SiteHeader');
      expect(src).toContain('className="s-prose"');
      expect(src).not.toMatch(/className="[^"]*\b(mx-auto|max-w-|text-\[|pt-16)\b/);
    }
  });
});
