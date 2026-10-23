import type { MetadataRoute } from 'next';
import { PAGES } from '@/lib/seo';
import { SITE_URL } from '@/lib/site';
import { waitlistOn } from '@/lib/waitlist-config';
import { USE_CASES, useCasePath } from '@/lib/use-cases';
import { COMPARE_LINKS } from '@/lib/compare';
import { BLOG_LINKS } from '@/lib/blog';

/** Every public page (src/lib/seo.ts), then the use-case pages (src/lib/use-cases.ts) and the comparison pages (src/lib/compare.ts) and the blog's articles (src/lib/blog.ts), on SHEPETAL_DOMAIN. Signed-in pages, the app sign-in, the install step and the
 * API stay out (robots.ts), and /waitlist while WAITLIST is off. */
export default function sitemap(): MetadataRoute.Sitemap {
  return [
    ...Object.values(PAGES).filter((p) => p.path !== '/waitlist' || waitlistOn()).map((p) => ({
      url: `${SITE_URL}${p.path === '/' ? '' : p.path}`,
      lastModified: p.updated,
      changeFrequency: p.freq,
      priority: p.priority,
    })),
    ...USE_CASES.map((u) => ({ url: `${SITE_URL}${useCasePath(u.slug)}`, lastModified: u.updated, changeFrequency: 'monthly' as const, priority: 0.6 })),
    ...COMPARE_LINKS.map((c) => ({ url: `${SITE_URL}${c.href}`, lastModified: c.updated, changeFrequency: 'monthly' as const, priority: 0.6 })),
    ...BLOG_LINKS.map((b) => ({ url: `${SITE_URL}${b.href}`, lastModified: b.updated, changeFrequency: 'monthly' as const, priority: 0.6 })),
  ];
}
