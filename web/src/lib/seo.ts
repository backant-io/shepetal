import type { Metadata } from 'next';
import pagesJson from './pages.json';
import { SITE_URL } from './site';

/**
 * The public pages (pages.json): their link preview (public/og/<key>.jpg, rendered by og/pages.mjs from `title` and
 * `sub`), their place in the sitemap, and their metadata. No price and no steps on a preview.
 */
type Page = { path: string; title: string; sub: string; updated: string; priority: number; freq: 'weekly' | 'monthly' | 'yearly' };
export const PAGES = pagesJson as Record<'home' | 'faq' | 'changelog' | 'press' | 'refunds' | 'privacy' | 'terms' | 'impressum' | 'legal', Page>;

export type PageKey = keyof typeof PAGES;

export const ogImage = (key: PageKey) => ({
  url: `/og/${key}.jpg`,
  width: 1200,
  height: 630,
  type: 'image/jpeg',
  alt: `shepetal. ${PAGES[key].title} The orange fn key on a concrete-white ground.`,
});

/** Canonical URL, Open Graph and the X card for one public page (Next replaces, not merges, a page's openGraph). */
export function pageMetadata(key: PageKey, { title, description }: { title?: string; description: string }): Metadata {
  const p = PAGES[key];
  const ogTitle = key === 'home' ? 'shepetal: press one key, your words appear' : `${title ?? p.title} - shepetal`;
  return {
    ...(title && { title }),
    description,
    alternates: { canonical: p.path },
    openGraph: { title: ogTitle, description, url: p.path, siteName: 'shepetal', type: 'website', locale: 'en_US', images: [ogImage(key)] },
    twitter: { card: 'summary_large_image', title: ogTitle, description, images: [ogImage(key)] },
  };
}

/** The landing page's structured data: the app with its two offers, and who makes it. */
export function softwareJsonLd() {
  return {
    '@context': 'https://schema.org',
    '@graph': [
      {
        '@type': 'SoftwareApplication',
        '@id': `${SITE_URL}/#app`,
        name: 'shepetal',
        description: 'Dictation for Mac. Press one key, and your words appear wherever you speak. Speech recognition runs on your Mac.',
        url: SITE_URL,
        image: `${SITE_URL}/og/home.jpg`,
        applicationCategory: 'ProductivityApplication',
        operatingSystem: 'macOS 14.4 or later (Apple silicon)',
        downloadUrl: `${SITE_URL}/download`,
        offers: [
          { '@type': 'Offer', name: 'Lifetime license', price: '23.99', priceCurrency: 'USD', url: `${SITE_URL}/account#plans`, availability: 'https://schema.org/InStock' },
          {
            '@type': 'Offer',
            name: 'Monthly subscription',
            price: '0.99',
            priceCurrency: 'USD',
            url: `${SITE_URL}/account#plans`,
            availability: 'https://schema.org/InStock',
            priceSpecification: { '@type': 'UnitPriceSpecification', price: '0.99', priceCurrency: 'USD', billingDuration: 'P1M', unitCode: 'MON' },
          },
        ],
        publisher: { '@id': `${SITE_URL}/#org` },
      },
      { '@type': 'Organization', '@id': `${SITE_URL}/#org`, name: 'BackAnt, Inc.', url: SITE_URL, logo: `${SITE_URL}/press/shepetal-icon-512.png`, email: 'support@shepetal.app' },
      { '@type': 'WebSite', '@id': `${SITE_URL}/#site`, name: 'shepetal', url: SITE_URL, publisher: { '@id': `${SITE_URL}/#org` } },
    ],
  };
}

/** JSON for a <script type="application/ld+json">: no "<" can end the script early. */
export const jsonLd = (data: unknown) => JSON.stringify(data).replace(/</g, '\\u003c');
