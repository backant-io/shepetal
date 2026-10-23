import type { MetadataRoute } from 'next';
import { PAGES } from '@/lib/seo';
import { SITE_URL } from '@/lib/site';
import { waitlistOn } from '@/lib/waitlist-config';

/** Every public page (src/lib/seo.ts), on SHEPETAL_DOMAIN. Signed-in pages, the app sign-in, the install step and the
 * API stay out (robots.ts), and /waitlist while WAITLIST is off. */
export default function sitemap(): MetadataRoute.Sitemap {
  return Object.values(PAGES).filter((p) => p.path !== '/waitlist' || waitlistOn()).map((p) => ({
    url: `${SITE_URL}${p.path === '/' ? '' : p.path}`,
    lastModified: p.updated,
    changeFrequency: p.freq,
    priority: p.priority,
  }));
}
