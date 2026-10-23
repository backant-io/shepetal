import type { Metadata } from 'next';
import { COMPARISONS, ROWS, comparePath, guidePath, type Fact, type Pick, type RowKey } from './compare';
import { ogImage } from './seo';
import { SITE_URL } from './site';
import { useCasePath } from './use-cases';

/**
 * The blog: /blog and /blog/<slug>, one static page each (src/app/(site)/blog/…/page.tsx), in the sitemap. Each article
 * puts apps the comparison pages (src/lib/compare.ts) leave out next to the ones they cover, and links those pages for
 * the rest. Plain text only, so the tests read exactly what the page says.
 *
 * The same rules as the comparison pages (EU comparative advertising, Directive 2006/114/EC, Art. 4): only objective,
 * verifiable, material facts about another app, each quoting its own public page, linked, with the date it was read.
 * The four apps with a comparison page bring their facts from compare.ts, so a fact is written and checked in one place.
 * shepetal's side is compare.ts SHEPETAL. Copy in Pavel's voice (the pavel-voice skill) and the brand rules.
 */
export type AppKey = 'wispr-flow' | 'superwhisper' | 'macwhisper' | 'apple-dictation' | 'aqua-voice' | 'willow' | 'voiceink' | 'dragon';

export type App = {
  key: AppKey;
  /** the app's name, as text */
  name: string;
  /** a row with no fact its own pages state is left out of the table */
  facts: Partial<Record<RowKey, Fact>>;
  /** its comparison page, when it has one */
  compare?: string;
};

/** The day every source below was read. A fact changes with its source: read the page, then change the text and this date. */
const ASOF = '2026-10-23';
const fact = (text: string, ...sources: string[]): Fact => ({ text, sources, asOf: ASOF });

const AQUA = { pricing: 'https://aquavoice.com/pricing', mac: 'https://aquavoice.com/mac' };
const WILLOW = { home: 'https://willowvoice.com', pricing: 'https://willowvoice.com/pricing', privacy: 'https://willowvoice.com/privacy-policy' };
const VOICEINK = { home: 'https://tryvoiceink.com', pricing: 'https://tryvoiceink.com/pricing' };
const DRAGON = 'https://dragon.nuance.com/en-us/dragon';

const fromCompare = (key: AppKey): App => {
  const c = COMPARISONS.find((x) => x.slug === key);
  if (!c) throw new Error(`no comparison ${key}`);
  return { key, name: c.name, facts: c.facts, compare: comparePath(c.slug) };
};

export const APPS: Record<AppKey, App> = {
  'wispr-flow': fromCompare('wispr-flow'),
  superwhisper: fromCompare('superwhisper'),
  macwhisper: fromCompare('macwhisper'),
  'apple-dictation': fromCompare('apple-dictation'),
  'aqua-voice': {
    key: 'aqua-voice',
    name: 'Aqua Voice',
    facts: {
      processing: fact('In the cloud. Its Mac page says Aqua processes audio in the cloud.', AQUA.mac),
      offline: fact('No. Its Mac page: “there is no offline mode.”', AQUA.mac),
      platforms: fact('Mac, Windows, iOS and Android.', AQUA.pricing),
      price: fact('Free: 1,000 free words. Pro: $8 / month billed annually, or $10 / month month-to-month. Max and Business plans too.', AQUA.pricing),
      languages: fact('49 languages.', AQUA.mac),
      anyApp: fact('Yes. Its Mac page: “if you can place a cursor in it, you can dictate into it.”', AQUA.mac),
    },
  },
  willow: {
    key: 'willow',
    name: 'Willow',
    facts: {
      processing: fact('In the cloud. Its privacy policy: “Willow uses cloud infrastructure to provide fast and accurate voice dictation.”', WILLOW.privacy),
      offline: fact('Yes, in its offline mode. Its site: “Dictate without an internet connection, powered entirely by your device.”', WILLOW.home),
      platforms: fact('Mac, Windows and iPhone, with Android marked “Coming soon”.', WILLOW.home, WILLOW.pricing),
      price: fact('Free plan. Pro: $15 user/mo, or $12 user/mo with annual billing (“Save 20%”). Business and Enterprise plans for teams.', WILLOW.pricing),
      languages: fact('100+ languages.', WILLOW.home),
      anyApp: fact('Yes. Its site: “Speak into any app”.', WILLOW.home),
    },
  },
  voiceink: {
    key: 'voiceink',
    name: 'VoiceInk',
    facts: {
      processing: fact('On your Mac. Its site: “Your voice data never leaves your Mac.” Its Cloud Enhancement, for the transcribed text, is optional.', VOICEINK.home),
      platforms: fact('Mac with Apple Silicon and macOS 14.4 or later, and an iOS version.', VOICEINK.pricing, VOICEINK.home),
      price: fact('Solo: $25, 1 macOS device. Personal: $39, 2 macOS devices. Extended: $49, 3 macOS devices. One-time purchase, lifetime access.', VOICEINK.pricing),
      anyApp: fact('Yes. Its site: “write anywhere, in any application”.', VOICEINK.home),
    },
  },
  dragon: {
    key: 'dragon',
    name: 'Dragon',
    facts: {
      processing: fact('Dragon Professional v16 is “Locally installed”, and the Dragon Anywhere products are “cloud-hosted”.', DRAGON),
      platforms: fact('Windows. Its page: Dragon Professional v16 is “optimized for Windows 11”. The page names no Mac version.', DRAGON),
      price: fact('No price on its page. Licensing goes through its “Contact us” link.', DRAGON),
    },
  },
};

/** A paragraph. It carries the sources of what it says about another app. */
export type Para = { text: string; sources?: string[]; asOf?: string };

export type Article = {
  slug: string;
  /** <title> (before " - shepetal") and the link preview */
  title: string;
  description: string;
  h1: string;
  lede: string;
  /** the other apps in the table, after shepetal */
  apps: AppKey[];
  /** the table's rows with two apps or fewer (apps as columns), its columns with more (apps as rows) */
  rows: RowKey[];
  sections: { title: string; paras: Para[] }[];
  /** "Pick <app> if", per app, then "Pick shepetal if" */
  picks: { app: AppKey; picks: Pick[] }[];
  pickShepetal: Pick[];
  /** the site's own pages to read next */
  next: { href: string; label: string }[];
  published: string;
  updated: string;
};

const ON_DEVICE = 'You want every dictation processed on your Mac, which is the only way shepetal works.';
const ONCE = 'You want to pay once and keep it.\n$23.99 once. Yours forever.';
const MONTHLY = 'You want to pay by the month.\n$0.99 a month.';
const ALL: RowKey[] = ROWS.map((r) => r.key);

export const ARTICLES: Article[] = [
  {
    slug: 'dictation-apps-mac',
    title: 'Dictation apps for Mac, side by side',
    description: 'Eight dictation apps for Mac in one table: where your voice is processed, offline use, platforms and price, with the source and date of every fact.',
    h1: 'Dictation apps for Mac',
    lede: 'Until now you opened five pricing pages in five tabs to find out which dictation app keeps your voice on your Mac and what it costs. You don’t have to do that anymore. We have put eight of them into one table, and every line on another app links the page it comes from and the day we checked it.',
    apps: ['wispr-flow', 'superwhisper', 'macwhisper', 'apple-dictation', 'aqua-voice', 'willow', 'voiceink'],
    rows: ['processing', 'offline', 'platforms', 'price'],
    sections: [
      {
        title: 'Start simple',
        paras: [
          { text: 'Pick the one thing that matters most to you and read that column first, then install the app that fits and use it for a week in the apps you write in every day, because that is where you find out if it works for you.' },
        ],
      },
      {
        title: 'On your Mac',
        paras: [
          { text: 'shepetal processes every dictation on your Mac and your voice stays there. It goes online once, to download speech recognition, and after that you can dictate on a plane or on a train with the wifi switched off.' },
          {
            text: 'MacWhisper and VoiceInk also process your voice on your Mac, Superwhisper lets you choose between your device and the cloud, and Wispr Flow, Aqua Voice and Willow transcribe in the cloud.',
            sources: [VOICEINK.home, 'https://www.macwhisper.com', 'https://superwhisper.com/docs/get-started/introduction', 'https://wisprflow.ai/privacy', AQUA.mac, WILLOW.privacy],
            asOf: ASOF,
          },
        ],
      },
    ],
    picks: [
      { app: 'wispr-flow', picks: [{ text: 'You want the same app on Windows, iOS and Android, and a free plan you can keep using.' }] },
      { app: 'superwhisper', picks: [{ text: 'You want to choose between processing on your device and in the cloud.' }] },
      { app: 'macwhisper', picks: [{ text: 'You also want to transcribe recordings you already have.', source: 'https://www.macwhisper.com', asOf: ASOF }] },
      { app: 'apple-dictation', picks: [{ text: 'You want to use what is already part of macOS.' }] },
      { app: 'aqua-voice', picks: [{ text: 'You want one subscription for your Mac, Windows, iPhone and Android.', source: AQUA.mac, asOf: ASOF }] },
      { app: 'willow', picks: [{ text: 'You dictate on Mac, Windows and iPhone and want the same app on all three.' }] },
      { app: 'voiceink', picks: [{ text: 'You have a Mac with Apple Silicon and want to pay once for two or three of them.' }] },
    ],
    pickShepetal: [{ text: ON_DEVICE }, { text: ONCE }, { text: MONTHLY }],
    next: [
      { href: guidePath('offline-dictation-mac'), label: 'Offline dictation' },
      { href: guidePath('private-dictation-mac'), label: 'Private dictation' },
      { href: useCasePath('privacy'), label: 'shepetal for private work' },
    ],
    published: '2026-10-21',
    updated: ASOF,
  },
  {
    slug: 'wispr-flow-vs-aqua-voice',
    title: 'Wispr Flow vs Aqua Voice',
    description: 'Wispr Flow and Aqua Voice next to each other and next to shepetal: where your voice is processed, offline use, platforms, price and languages, each sourced.',
    h1: 'Wispr Flow or Aqua Voice',
    lede: 'Until now you read two pricing pages and two privacy pages and still had to put the answers next to each other in your head. We have done that for you here, with shepetal in the table too, and every line on Wispr Flow and Aqua Voice links the page it comes from and the day we checked it.',
    apps: ['wispr-flow', 'aqua-voice'],
    rows: ALL,
    sections: [
      {
        title: 'Where they are alike',
        paras: [
          {
            text: 'Wispr Flow and Aqua Voice both transcribe your voice in the cloud and both put your words into the app you are working in, on Mac, Windows, iOS and Android.',
            sources: ['https://wisprflow.ai/privacy', 'https://wisprflow.ai/pricing', AQUA.mac, AQUA.pricing],
            asOf: ASOF,
          },
        ],
      },
      {
        title: 'Where they differ',
        paras: [
          {
            text: 'Wispr Flow lists 100+ languages and a Notetaker for meetings, and Aqua Voice lists 49 languages. Both have a free plan to start with, and the table has each price the way its own pricing page shows it.',
            sources: ['https://wisprflow.ai/pricing', AQUA.mac, AQUA.pricing],
            asOf: ASOF,
          },
        ],
      },
      {
        title: 'Where shepetal fits',
        paras: [
          { text: 'shepetal processes every dictation on your Mac, so it is the one to look at when you want your voice to stay with you. You go online once to download speech recognition and after that it works on a plane, on a train or anywhere else with no signal.' },
        ],
      },
    ],
    picks: [
      { app: 'wispr-flow', picks: [{ text: 'You speak a language outside the 49 on Aqua Voice’s list, or you want meeting notes in the same app.', source: AQUA.mac, asOf: ASOF }] },
      { app: 'aqua-voice', picks: [{ text: 'You want one subscription for your Mac, Windows, iPhone and Android.', source: AQUA.mac, asOf: ASOF }] },
    ],
    pickShepetal: [{ text: 'You want your voice to stay on your Mac the whole time.\n100% private. Your data is yours.' }, { text: 'You dictate where you have no internet.\nWorks offline.' }, { text: ONCE }],
    next: [
      { href: comparePath('wispr-flow'), label: 'shepetal or Wispr Flow' },
      { href: '/blog/wispr-flow-vs-willow', label: 'Wispr Flow or Willow' },
      { href: guidePath('private-dictation-mac'), label: 'Private dictation' },
    ],
    published: '2026-10-21',
    updated: ASOF,
  },
  {
    slug: 'wispr-flow-vs-willow',
    title: 'Wispr Flow vs Willow',
    description: 'Wispr Flow and Willow next to each other and next to shepetal: where your voice is processed, offline use, platforms, price and languages, each sourced.',
    h1: 'Wispr Flow or Willow',
    lede: 'Until now you compared Wispr Flow and Willow by switching between their pricing pages, and the plans look alike at first. We have put them into one table with shepetal next to them, and every line on Wispr Flow and Willow links the page it comes from and the day we checked it.',
    apps: ['wispr-flow', 'willow'],
    rows: ALL,
    sections: [
      {
        title: 'Where they are alike',
        paras: [
          {
            text: 'Both transcribe in the cloud, both list 100+ languages and both put your words into any app on your Mac. Both have a free plan, a Pro plan per user and plans for teams.',
            sources: ['https://wisprflow.ai/privacy', 'https://wisprflow.ai/pricing', WILLOW.privacy, WILLOW.home, WILLOW.pricing],
            asOf: ASOF,
          },
        ],
      },
      {
        title: 'Where they differ',
        paras: [
          {
            text: 'Willow lists an offline mode that runs on your device, and Wispr Flow says transcription happens in the cloud every time. Wispr Flow runs on Android today, and Willow marks Android as coming soon.',
            sources: [WILLOW.home, WILLOW.pricing, 'https://wisprflow.ai/privacy', 'https://wisprflow.ai/pricing'],
            asOf: ASOF,
          },
        ],
      },
      {
        title: 'Where shepetal fits',
        paras: [
          { text: 'shepetal processes every dictation on your Mac, the whole time and with no mode to switch on, and your recordings and history stay in your user folder. You pay once or by the month, and you can try it free for 30 days first.' },
        ],
      },
    ],
    picks: [
      { app: 'wispr-flow', picks: [{ text: 'You also dictate on Android and want the same app there.' }] },
      { app: 'willow', picks: [{ text: 'You want a cloud app with an offline mode for the times you have no signal.' }] },
    ],
    pickShepetal: [{ text: ON_DEVICE }, { text: ONCE }, { text: MONTHLY }],
    next: [
      { href: comparePath('wispr-flow'), label: 'shepetal or Wispr Flow' },
      { href: '/blog/wispr-flow-vs-aqua-voice', label: 'Wispr Flow or Aqua Voice' },
      { href: guidePath('offline-dictation-mac'), label: 'Offline dictation' },
    ],
    published: '2026-10-21',
    updated: ASOF,
  },
  {
    slug: 'wispr-flow-vs-voiceink',
    title: 'Wispr Flow vs VoiceInk',
    description: 'Wispr Flow, a cloud subscription, and VoiceInk, local and paid once, next to each other and next to shepetal, with the source and date of every fact.',
    h1: 'Wispr Flow or VoiceInk',
    lede: 'Until now the choice between Wispr Flow and VoiceInk came down to two questions you had to answer from four different pages: where does my voice go, and do I pay every month or once. We have put both answers into one table with shepetal next to them, and every line on the other two apps links its source and the day we checked it.',
    apps: ['wispr-flow', 'voiceink'],
    rows: ALL,
    sections: [
      {
        title: 'Where your voice goes',
        paras: [
          {
            text: 'Wispr Flow transcribes in the cloud, and VoiceInk transcribes on your Mac and sends only the transcribed text when you switch on its optional Cloud Enhancement.',
            sources: ['https://wisprflow.ai/privacy', VOICEINK.home],
            asOf: ASOF,
          },
        ],
      },
      {
        title: 'How you pay',
        paras: [
          {
            text: 'Wispr Flow is a subscription with a free plan, and VoiceInk is a one-time purchase per number of Macs. VoiceInk runs on a Mac with Apple Silicon and macOS 14.4 or later, and Wispr Flow also runs on Windows, iOS and Android.',
            sources: ['https://wisprflow.ai/pricing', VOICEINK.pricing],
            asOf: ASOF,
          },
        ],
      },
      {
        title: 'Where shepetal fits',
        paras: [
          { text: 'shepetal processes every dictation on your Mac and you choose between paying once and paying by the month. It runs on macOS 14 or later, on Apple silicon and on an Intel Mac too.' },
        ],
      },
    ],
    picks: [
      { app: 'wispr-flow', picks: [{ text: 'You want the same app on Windows, iOS and Android.' }] },
      { app: 'voiceink', picks: [{ text: 'You want local dictation on two or three Macs with one purchase.' }] },
    ],
    pickShepetal: [{ text: ON_DEVICE }, { text: 'You want to choose between paying once and paying by the month.\n$23.99 once. Yours forever.\n$0.99 a month.' }],
    next: [
      { href: comparePath('wispr-flow'), label: 'shepetal or Wispr Flow' },
      { href: comparePath('macwhisper'), label: 'shepetal or MacWhisper' },
      { href: guidePath('private-dictation-mac'), label: 'Private dictation' },
    ],
    published: '2026-10-21',
    updated: ASOF,
  },
  {
    slug: 'dragon-mac',
    title: 'Dragon on a Mac',
    description: 'You used Dragon and now you work on a Mac: what Dragon’s own page lists today, and how shepetal takes over your dictation on macOS, each fact sourced.',
    h1: 'From Dragon to your Mac',
    lede: 'Until now you dictated with Dragon on a PC, and now the computer on your desk is a Mac. We have put what Dragon’s own page lists today next to shepetal, so you can see what you get on macOS and start dictating on the Mac you have.',
    apps: ['dragon'],
    rows: ALL,
    sections: [
      {
        title: 'What Dragon lists',
        paras: [
          {
            text: 'Dragon’s page lists Dragon Professional v16 for Windows 11 as a locally installed app, and the Dragon Anywhere products as cloud-hosted, with licensing through Contact us.',
            sources: [DRAGON],
            asOf: ASOF,
          },
        ],
      },
      {
        title: 'On your Mac',
        paras: [
          { text: 'You install shepetal and it downloads speech recognition once, and from then on you speak and your words appear wherever your cursor is, in every app, and every dictation is processed on your Mac.' },
          { text: 'shepetal knows 25 European languages on a Mac with Apple silicon, among them English, German, French, Spanish, Italian and Polish, and English on an Intel Mac.' },
        ],
      },
    ],
    picks: [{ app: 'dragon', picks: [{ text: 'You work on Windows 11 and want a Dragon app installed on your PC.', source: DRAGON, asOf: ASOF }] }],
    pickShepetal: [{ text: 'You work on a Mac and want your words in every app.\nWorks in every app.' }, { text: ON_DEVICE }, { text: ONCE }],
    next: [
      { href: comparePath('apple-dictation'), label: 'shepetal or Apple Dictation' },
      { href: useCasePath('writers'), label: 'shepetal for writers' },
      { href: useCasePath('rsi'), label: 'shepetal for RSI' },
    ],
    published: '2026-10-21',
    updated: ASOF,
  },
];

export const article = (slug: string): Article => {
  const a = ARTICLES.find((x) => x.slug === slug);
  if (!a) throw new Error(`no article ${slug}`);
  return a;
};

export const BLOG = {
  title: 'Blog',
  description: 'Dictation apps for Mac side by side: where your voice is processed, offline use, platforms and price, with the source and date of every fact.',
  h1: 'The shepetal blog',
  lede: 'Until now you had to read every dictation app’s pricing and privacy pages yourself to find out where your voice goes and what you pay. We have put the dictation apps for Mac next to each other, and every line on another app links the page it comes from and the day we checked it.',
};

export const blogPath = (slug?: string) => (slug ? `/blog/${slug}` : '/blog');
/** The trial button's ?ref=: blog-<slug> on an article, blog on the index. */
export const blogRef = (slug?: string) => (slug ? `blog-${slug}` : 'blog');

/** Every fact about another app an article states: the table's, in table order, then the paragraphs' and picks' sources. */
export const factsOfArticle = (a: Article) =>
  a.apps.map((k) => {
    const app = APPS[k];
    const keys = a.rows.filter((r) => app.facts[r]);
    return { app, facts: keys.map((r) => ({ key: r, label: ROWS.find((x) => x.key === r)!.label, ...app.facts[r]! })) };
  });

/** Canonical URL, Open Graph and the X card, with the blog's link preview (public/og/blog.jpg). */
function metadataFor(path: string, title: string, description: string, type: 'website' | 'article'): Metadata {
  const ogTitle = `${title} - shepetal`;
  const images = [ogImage('blog')];
  return {
    title,
    description,
    alternates: { canonical: path },
    openGraph: { title: ogTitle, description, url: path, siteName: 'shepetal', type, locale: 'en_US', images },
    twitter: { card: 'summary_large_image', title: ogTitle, description, images },
  };
}

export const articleMetadata = (slug: string) => {
  const a = article(slug);
  return metadataFor(blogPath(slug), a.title, a.description, 'article');
};

const org = { '@type': 'Organization', name: 'BackAnt, Inc.', url: SITE_URL };

/** An article's structured data: the Article and its breadcrumb. */
export function articleJsonLd(a: Article) {
  const url = `${SITE_URL}${blogPath(a.slug)}`;
  return {
    '@context': 'https://schema.org',
    '@graph': [
      {
        '@type': 'Article',
        '@id': `${url}#article`,
        headline: a.h1,
        description: a.description,
        url,
        mainEntityOfPage: url,
        datePublished: a.published,
        dateModified: a.updated,
        inLanguage: 'en',
        image: `${SITE_URL}${ogImage('blog').url}`,
        author: org,
        publisher: org,
      },
      {
        '@type': 'BreadcrumbList',
        itemListElement: [
          { '@type': 'ListItem', position: 1, name: 'shepetal', item: SITE_URL },
          { '@type': 'ListItem', position: 2, name: 'Blog', item: `${SITE_URL}${blogPath()}` },
          { '@type': 'ListItem', position: 3, name: a.h1, item: url },
        ],
      },
    ],
  };
}

/** The index's structured data: the Blog and its posts. */
export function blogJsonLd() {
  const url = `${SITE_URL}${blogPath()}`;
  return {
    '@context': 'https://schema.org',
    '@type': 'Blog',
    '@id': `${url}#blog`,
    name: BLOG.h1,
    url,
    inLanguage: 'en',
    publisher: org,
    blogPost: ARTICLES.map((a) => ({ '@type': 'BlogPosting', headline: a.h1, url: `${SITE_URL}${blogPath(a.slug)}`, datePublished: a.published, dateModified: a.updated })),
  };
}

/** The articles in the sitemap (the index is a public page in pages.json). */
export const BLOG_LINKS = ARTICLES.map((a) => ({ href: blogPath(a.slug), updated: a.updated }));
