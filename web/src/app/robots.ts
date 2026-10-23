import type { MetadataRoute } from 'next';
import { SITE_URL } from '@/lib/site';

/** Crawl the public pages; keep crawlers out of the API, the app sign-in, the account, the install step and the files. */
export default function robots(): MetadataRoute.Robots {
  return {
    rules: [{ userAgent: '*', allow: '/', disallow: ['/api/', '/app/', '/account', '/install', '/download'] }],
    sitemap: `${SITE_URL}/sitemap.xml`,
    host: SITE_URL,
  };
}
