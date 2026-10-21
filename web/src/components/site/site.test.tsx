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

  it('use the site’s header, type and prose', () => {
    for (const p of ['privacy', 'terms', 'legal']) {
      const src = page(p);
      expect(src).toContain('<SiteHeader');
      expect(src).toContain('className="s-prose"');
      expect(src).not.toMatch(/className="[^"]*\b(mx-auto|max-w-|text-\[|pt-16)\b/);
    }
  });
});
