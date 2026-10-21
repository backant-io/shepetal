import { APPS } from './apps';
import type { Article } from './types';

export const SITE = 'https://shepetal.backant.io';
/** The blog speaks in the brand voice ("we"), so shepetal is the author. */
export const AUTHOR = { name: 'shepetal' };
export const TWITTER = '@shepetal_app';

/** The lines the call to action carries (components/blog/parts.tsx). Articles leave them to it, so each is said once a page. */
export const CTA_CLAIMS = ['Write at the speed of thought.', 'Press one key. Your words appear wherever you speak.', '30 days free', '$4.99. Yours forever.', 'For Mac.'];

/** ISO date and time, with the zone, for structured data and Open Graph. */
export const isoTime = (date: string) => `${date}T09:00:00+02:00`;

/** The last breadcrumb: the keyword in sentence case, short enough for the trail and the same in the JSON-LD. */
export const crumbOf = (a: Article) => a.keyword.charAt(0).toUpperCase() + a.keyword.slice(1);

/** The link preview for the blog: one static image per article, built by og/blog-og.mjs. No price on it. */
export const ogImageFor = (a: Article) => ({
  url: `/blog/og/${a.slug}.jpg`,
  width: 1200,
  height: 630,
  type: 'image/jpeg',
  alt: `${a.title}. The shepetal wordmark on the dusk afterglow.`,
});

const abs = (path: string) => `${SITE}${path}`;

const publisher = {
  '@type': 'Organization',
  name: 'shepetal',
  url: SITE,
  logo: { '@type': 'ImageObject', url: abs('/icon-512.png'), width: 512, height: 512 },
};

/** Article, BreadcrumbList, and FAQPage and ItemList where the article has them, as one @graph. */
export function articleJsonLd(a: Article) {
  const url = abs(`/blog/${a.slug}`);
  const graph: Record<string, unknown>[] = [
    {
      '@type': 'Article',
      '@id': `${url}#article`,
      headline: a.title,
      description: a.description,
      url,
      mainEntityOfPage: url,
      datePublished: isoTime(a.published),
      dateModified: isoTime(a.updated),
      inLanguage: 'en',
      image: abs(ogImageFor(a).url),
      author: { '@type': 'Organization', name: AUTHOR.name, url: SITE },
      publisher,
      about: a.apps.map((id) => ({ '@type': 'SoftwareApplication', name: APPS[id].name, url: APPS[id].url })),
      keywords: a.keyword,
    },
    {
      '@type': 'BreadcrumbList',
      itemListElement: [
        { '@type': 'ListItem', position: 1, name: 'shepetal', item: SITE },
        { '@type': 'ListItem', position: 2, name: 'Blog', item: abs('/blog') },
        { '@type': 'ListItem', position: 3, name: crumbOf(a), item: url },
      ],
    },
  ];
  if (a.faq.length) {
    graph.push({
      '@type': 'FAQPage',
      '@id': `${url}#faq`,
      mainEntity: a.faq.map((f) => ({ '@type': 'Question', name: f.q, acceptedAnswer: { '@type': 'Answer', text: f.a } })),
    });
  }
  if (a.ranked) {
    graph.push({
      '@type': 'ItemList',
      name: a.title,
      itemListOrder: 'https://schema.org/ItemListOrderAscending',
      itemListElement: a.ranked.map((id, i) => ({
        '@type': 'ListItem',
        position: i + 1,
        name: APPS[id].name,
        url: `${url}#${i + 1}-${id}`,
      })),
    });
  }
  return { '@context': 'https://schema.org', '@graph': graph };
}

export function blogJsonLd(list: Article[]) {
  return {
    '@context': 'https://schema.org',
    '@graph': [
      {
        '@type': 'Blog',
        '@id': `${abs('/blog')}#blog`,
        name: 'The shepetal blog',
        url: abs('/blog'),
        inLanguage: 'en',
        publisher,
        blogPost: list.map((a) => ({
          '@type': 'BlogPosting',
          headline: a.title,
          url: abs(`/blog/${a.slug}`),
          datePublished: isoTime(a.published),
          dateModified: isoTime(a.updated),
          author: { '@type': 'Organization', name: AUTHOR.name, url: SITE },
        })),
      },
      {
        '@type': 'BreadcrumbList',
        itemListElement: [
          { '@type': 'ListItem', position: 1, name: 'shepetal', item: SITE },
          { '@type': 'ListItem', position: 2, name: 'Blog', item: abs('/blog') },
        ],
      },
    ],
  };
}

/** JSON for a <script type="application/ld+json">, with < escaped so no text can close the tag. */
export const ldJson = (data: unknown) => JSON.stringify(data).replace(/</g, '\\u003c');
