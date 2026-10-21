import type { MetadataRoute } from 'next';
import { ARTICLES } from '../lib/blog/articles';
import { SITE } from '../lib/blog/seo';

/** Every public page. Signed-in pages (/account), the app sign-in (/app) and the API stay out (robots.ts). */
const PAGES: { path: string; changeFrequency: 'weekly' | 'monthly' | 'yearly'; priority: number; lastModified: string }[] = [
  { path: '/', changeFrequency: 'weekly', priority: 1, lastModified: '2026-10-21' },
  { path: '/privacy', changeFrequency: 'yearly', priority: 0.3, lastModified: '2026-10-20' },
  { path: '/terms', changeFrequency: 'yearly', priority: 0.3, lastModified: '2026-10-20' },
];

export default function sitemap(): MetadataRoute.Sitemap {
  return [
    { url: `${SITE}/blog`, lastModified: ARTICLES.map((a) => a.updated).sort().at(-1), changeFrequency: 'weekly' as const, priority: 0.8 },
    ...PAGES.map((p) => ({ url: `${SITE}${p.path === '/' ? '' : p.path}`, lastModified: p.lastModified, changeFrequency: p.changeFrequency, priority: p.priority })),
    ...ARTICLES.map((a) => ({
      url: `${SITE}/blog/${a.slug}`,
      lastModified: a.updated,
      changeFrequency: 'monthly' as const,
      priority: a.kind === 'comparison' ? 0.6 : 0.7,
    })),
  ];
}
