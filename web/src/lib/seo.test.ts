import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import robots from '@/app/robots';
import sitemap from '@/app/sitemap';
import { PAGES, pageMetadata, softwareJsonLd } from './seo';
import { SITE_URL } from './site';
import { USE_CASES } from './use-cases';
import { COMPARE_LINKS } from './compare';

const WEB = join(__dirname, '..', '..');

describe('discovery', () => {
  it('lists every public page in the sitemap on the domain, and nothing signed-in', () => {
    const urls = sitemap().map((e) => e.url);
    expect(urls).toEqual([
      ...Object.values(PAGES).map((p) => `${SITE_URL}${p.path === '/' ? '' : p.path}`),
      ...USE_CASES.map((u) => `${SITE_URL}/for/${u.slug}`),
      ...COMPARE_LINKS.map((c) => `${SITE_URL}${c.href}`),
    ]);
    for (const p of ['/faq', '/press', '/changelog', '/refunds', '/impressum', '/privacy', '/terms', '/legal']) expect(urls).toContain(`${SITE_URL}${p}`);
    expect(urls.some((u) => /account|install|download|\/app\b|\/api\//.test(u))).toBe(false);
  });

  it('points robots at the sitemap and keeps crawlers out of the API, sign-in, account, install and files', () => {
    const r = robots();
    expect(r.sitemap).toBe(`${SITE_URL}/sitemap.xml`);
    expect(r.rules).toEqual([{ userAgent: '*', allow: '/', disallow: ['/api/', '/app/', '/account', '/install', '/download'] }]);
  });

  it('gives every public page its canonical URL and its own link preview, which exists', () => {
    for (const [key, p] of Object.entries(PAGES)) {
      const m = pageMetadata(key as keyof typeof PAGES, { description: 'd' });
      expect(m.alternates?.canonical).toBe(p.path);
      const img = (m.openGraph?.images as { url: string }[])[0];
      expect(img.url).toBe(`/og/${key}.jpg`);
      expect(existsSync(join(WEB, 'public', img.url)), img.url).toBe(true);
      expect(`${p.title} ${p.sub}`).not.toMatch(/\$|hold fn|let go/i);
      if (key !== 'home') {
        const src = readFileSync(join(WEB, 'src', 'app', '(site)', key, 'page.tsx'), 'utf8');
        expect(src, key).toContain(`pageMetadata('${key}'`);
      }
    }
    expect(readFileSync(join(WEB, 'src', 'app', '(story)', 'page.tsx'), 'utf8')).toContain("pageMetadata('home'");
  });

  it('describes the app with its two offers, $23.99 once and $0.99 a month', () => {
    const graph = softwareJsonLd()['@graph'];
    const app = graph.find((n) => n['@type'] === 'SoftwareApplication') as { offers: { price: string; priceSpecification?: { billingDuration: string } }[]; operatingSystem: string; url: string };
    expect(app.url).toBe(SITE_URL);
    expect(app.operatingSystem).toMatch(/macOS 14\.4/);
    expect(app.offers.map((o) => o.price)).toEqual(['23.99', '0.99']);
    expect(app.offers[1].priceSpecification?.billingDuration).toBe('P1M');
    expect(JSON.stringify(graph)).not.toMatch(/backant\.io/i);
  });
});
