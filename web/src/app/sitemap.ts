import type { MetadataRoute } from 'next';
import { PAGES } from '@/lib/seo';
import { SITE_URL } from '@/lib/site';

/** Every public page (src/lib/seo.ts), on SHEPETAL_DOMAIN. Signed-in pages, the app sign-in, the install step and the
 * API stay out (robots.ts). */
export default function sitemap(): MetadataRoute.Sitemap {
  return Object.values(PAGES).map((p) => ({
    url: `${SITE_URL}${p.path === '/' ? '' : p.path}`,
    lastModified: p.updated,
    changeFrequency: p.freq,
    priority: p.priority,
  }));
}
