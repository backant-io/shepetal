import type { MetadataRoute } from 'next';
import { PAGES } from '@/lib/seo';
import { SITE_URL } from '@/lib/site';
import { COMPARE_LINKS } from '@/lib/compare';

/** Every public page (src/lib/seo.ts), then the comparison pages (src/lib/compare.ts), on SHEPETAL_DOMAIN. Signed-in pages, the app sign-in, the install step and the
 * API stay out (robots.ts). */
export default function sitemap(): MetadataRoute.Sitemap {
  return [
    ...Object.values(PAGES).map((p) => ({
      url: `${SITE_URL}${p.path === '/' ? '' : p.path}`,
      lastModified: p.updated,
      changeFrequency: p.freq,
      priority: p.priority,
    })),
    ...COMPARE_LINKS.map((c) => ({ url: `${SITE_URL}${c.href}`, lastModified: c.updated, changeFrequency: 'monthly' as const, priority: 0.6 })),
  ];
}
