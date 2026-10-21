import type { MetadataRoute } from 'next';
import { SITE } from '../lib/blog/seo';

/** Crawl the public pages; keep crawlers out of the API, the app sign-in, the account page and the signed-in download. */
export default function robots(): MetadataRoute.Robots {
  return {
    rules: [{ userAgent: '*', allow: '/', disallow: ['/api/', '/app/', '/account', '/download'] }],
    sitemap: `${SITE}/sitemap.xml`,
    host: SITE,
  };
}
