import type { Metadata } from 'next';
import { ogImage } from './seo';

/**
 * The comparison pages: /compare/<slug>, one per app, and the two search guides /offline-dictation-mac and
 * /private-dictation-mac. Each is a static page (src/app/(site)/…/page.tsx) in the sitemap and in the footer's "Compare"
 * list. Plain text only, so the tests read exactly what the page says.
 *
 * EU comparative advertising (Directive 2006/114/EC, Art. 4): only objective, verifiable, material facts. Every fact
 * about another app quotes its own public page, linked, with the date it was read. The names are text only: no logo, no
 * trademark styling. No model name, no other app's price in numbers, no number but shepetal's approved ones.
 */
export type RowKey = 'processing' | 'offline' | 'platforms' | 'price' | 'meetings' | 'anyApp';

export const ROWS: { key: RowKey; label: string }[] = [
  { key: 'processing', label: 'On-device or cloud' },
  { key: 'offline', label: 'Offline use' },
  { key: 'platforms', label: 'Platforms' },
  { key: 'price', label: 'Pricing' },
  { key: 'meetings', label: 'Meeting transcription' },
  { key: 'anyApp', label: 'Works in any app' },
];

/** shepetal's side of every table: the FAQ, the landing page and the approved claims, word for word. */
export const SHEPETAL: Record<RowKey, string> = {
  processing: 'On-device processing. Your voice never leaves your Mac.',
  offline: 'Works offline. You are online once to set up.',
  platforms: 'Mac. macOS 14.4 or later on Apple silicon.',
  price: '$23.99 once. Yours forever. Or $0.99 a month. 30 days free.',
  meetings: 'Meetings, transcribed on your Mac. The meeting reminder appears when a call starts.',
  anyApp: 'Works in every app.',
};

/** A fact about another app: what its own public page says, the page, and the day it was read. */
export type Fact = { text: string; sources: string[]; asOf: string };

/** A line of "when to pick which"; `source` when it states something the table does not. */
export type Pick = { text: string; source?: string; asOf?: string };

export type Comparison = {
  slug: string;
  /** the other app's name, as text */
  name: string;
  title: string;
  description: string;
  h1: string;
  lede: string;
  facts: Record<RowKey, Fact>;
  pickOther: Pick[];
  pickShepetal: Pick[];
  updated: string;
};

/** The landing page's trial button (Story.tsx TRY). */
export const TRY = 'Try 30 days free';

const ASOF = '2026-10-22';

const WISPR = {
  pricing: 'https://wisprflow.ai/pricing',
  privacy: 'https://wisprflow.ai/privacy',
  offline: 'https://docs.wisprflow.ai/articles/3834764683-why-vpns-or-security-tools-can-block-wispr-flow',
};
const SUPERWHISPER = { home: 'https://superwhisper.com', docs: 'https://superwhisper.com/docs', meetings: 'https://superwhisper.com/docs/meetings/overview' };
const MACWHISPER = 'https://macwhisper.com';
const APPLE = {
  dictation: 'https://support.apple.com/en-us/guide/mac-help/mh40584/14.0/mac/14.0',
  privacy: 'https://www.apple.com/legal/privacy/data/en/ask-siri-dictation/',
  iphone: 'https://support.apple.com/guide/iphone/dictate-text-iph2c0651d2/ios',
};

const fact = (text: string, ...sources: string[]): Fact => ({ text, sources, asOf: ASOF });

export const COMPARISONS: Comparison[] = [
  {
    slug: 'wispr-flow',
    name: 'Wispr Flow',
    title: 'shepetal vs Wispr Flow',
    description: 'shepetal and Wispr Flow side by side: on-device or cloud processing, offline use, platforms, pricing and meetings. Each fact linked to its source.',
    h1: 'shepetal or Wispr Flow.',
    lede: 'Both put your words in any app. shepetal processes your voice on your Mac. Wispr Flow processes it in the cloud.',
    facts: {
      processing: fact('Cloud processing. Its privacy page says transcription always happens in the cloud.', WISPR.privacy),
      offline: fact('No. Its help center says that offline, starting a dictation shows “No internet. Try again later.”', WISPR.offline),
      platforms: fact('Mac, Windows, iOS and Android.', WISPR.pricing),
      price: fact('A free plan with a weekly word limit. Paid plans by subscription, billed monthly or yearly.', WISPR.pricing),
      meetings: fact('Yes. Its Notetaker records meetings, on Mac and Windows.', WISPR.pricing),
      anyApp: fact('Yes.', WISPR.pricing),
    },
    pickOther: [
      { text: 'You dictate on Windows, iOS or Android as well as on your Mac.' },
      { text: 'You speak a language outside shepetal’s 25 European languages.', source: WISPR.pricing, asOf: ASOF },
      { text: 'You want a free plan to keep, or plans for a team.' },
    ],
    pickShepetal: [
      { text: 'Your voice has to stay on your Mac. 100% private. Your data is yours.' },
      { text: 'You dictate where there is no internet. Works offline.' },
      { text: 'You want to pay once. $23.99 once. Yours forever.' },
    ],
    updated: ASOF,
  },
  {
    slug: 'superwhisper',
    name: 'Superwhisper',
    title: 'shepetal vs Superwhisper',
    description: 'shepetal and Superwhisper side by side: on-device or cloud processing, offline use, platforms, pricing and meetings. Each fact linked to its source.',
    h1: 'shepetal or Superwhisper.',
    lede: 'Both work in any app, and both work offline. shepetal processes on your Mac only. Superwhisper also offers cloud processing.',
    facts: {
      processing: fact('Your choice of on-device processing or cloud processing.', SUPERWHISPER.docs),
      offline: fact('Yes, with on-device processing. Its docs say some formatting features need the internet.', SUPERWHISPER.docs),
      platforms: fact('macOS, Windows, iOS and Android.', SUPERWHISPER.docs),
      price: fact('A free plan. Pro by subscription, monthly or yearly, or as a lifetime license.', SUPERWHISPER.home),
      meetings: fact('Yes, on Mac. It records calls with no bot in the call.', SUPERWHISPER.home, SUPERWHISPER.meetings),
      anyApp: fact('Yes.', SUPERWHISPER.docs),
    },
    pickOther: [
      { text: 'You want cloud processing as an option.' },
      { text: 'You dictate on Windows, iOS or Android as well as on your Mac.' },
      { text: 'You want a free plan to keep.' },
    ],
    pickShepetal: [
      { text: 'You want on-device processing and nothing else. shepetal has no cloud processing.' },
      { text: 'You want the meeting reminder when a call starts.' },
      { text: 'You want a simple price. $23.99 once. Yours forever. Or $0.99 a month.' },
    ],
    updated: ASOF,
  },
  {
    slug: 'macwhisper',
    name: 'MacWhisper',
    title: 'shepetal vs MacWhisper',
    description: 'shepetal and MacWhisper side by side: on-device or cloud processing, offline use, platforms, pricing and meetings. Each fact linked to its source.',
    h1: 'shepetal or MacWhisper.',
    lede: 'Both process your voice on your Mac, and both transcribe meetings. MacWhisper also transcribes files. shepetal is built around dictation in every app.',
    facts: {
      processing: fact('On-device processing. Cloud services are an option.', MACWHISPER),
      offline: fact('Yes. Its site lists offline processing on your Mac.', MACWHISPER),
      platforms: fact('Mac. Its site also lists an iOS and iPad version.', MACWHISPER),
      price: fact('A free version. Pro is a one-time purchase.', MACWHISPER),
      meetings: fact('Yes. It records meetings, with no bot in the call.', MACWHISPER),
      anyApp: fact('Yes, with its dictation feature.', MACWHISPER),
    },
    pickOther: [
      { text: 'You transcribe recorded files as well as dictate.', source: MACWHISPER, asOf: ASOF },
      { text: 'You want cloud services as an option.' },
      { text: 'You want a free version to keep.' },
    ],
    pickShepetal: [
      { text: 'You want on-device processing and nothing else. shepetal has no cloud processing.' },
      { text: 'You want the meeting reminder when a call starts.' },
      { text: 'You want to choose between paying once and $0.99 a month.' },
    ],
    updated: ASOF,
  },
  {
    slug: 'apple-dictation',
    name: 'Apple Dictation',
    title: 'shepetal vs Apple Dictation',
    description: 'shepetal and Apple Dictation side by side: on-device or cloud processing, offline use, platforms, pricing and meetings. Each fact linked to its source.',
    h1: 'shepetal or Apple Dictation.',
    lede: 'Apple Dictation is part of macOS, and it works anywhere you type. shepetal adds meeting transcription, and every request stays on your Mac.',
    facts: {
      processing: fact(
        'On-device on a Mac with Apple silicon, for supported languages. Otherwise, Apple’s servers process what you dictate.',
        APPLE.dictation,
        APPLE.privacy,
      ),
      offline: fact('Yes, on a Mac with Apple silicon, for supported languages.', APPLE.dictation),
      platforms: fact('Part of macOS and iOS.', APPLE.dictation, APPLE.iphone),
      price: fact('Included with macOS.', APPLE.dictation),
      meetings: fact('No. Dictation enters text where you type.', APPLE.dictation),
      anyApp: fact('Yes. Anywhere you can type.', APPLE.dictation),
    },
    pickOther: [
      { text: 'You want nothing to install. It is part of macOS.' },
      { text: 'You dictate on your iPhone too.' },
      { text: 'You want dictation at no extra cost.' },
    ],
    pickShepetal: [
      { text: 'You want meetings transcribed. Meetings, transcribed on your Mac.' },
      { text: 'You want every request processed on your Mac. shepetal has no cloud processing.' },
      { text: 'You want a history of what you said, kept on your Mac.' },
    ],
    updated: ASOF,
  },
];

/** The two search guides: shepetal's answer, then the same facts for the four apps above. */
export type Guide = {
  slug: 'offline-dictation-mac' | 'private-dictation-mac';
  /** the footer's "Compare" link */
  label: string;
  /** the trial button's ?ref= */
  ref: 'seo-offline' | 'seo-private';
  title: string;
  description: string;
  h1: string;
  lede: string;
  sections: { title: string; text: string }[];
  /** the table's fact columns */
  columns: RowKey[];
  /** "when to pick which", from the table */
  others: string;
  updated: string;
};

export const GUIDES: Guide[] = [
  {
    slug: 'offline-dictation-mac',
    label: 'Offline dictation',
    ref: 'seo-offline',
    title: 'Offline dictation for Mac',
    description: 'Dictation on your Mac with no internet: shepetal processes speech on your Mac. How it compares with Wispr Flow, Superwhisper, MacWhisper and Apple Dictation.',
    h1: 'Dictate with no internet.',
    lede: 'shepetal recognizes speech on your Mac. Works offline. Dictate on a plane, on a train, anywhere with no signal.',
    sections: [
      { title: 'Online once', text: 'You sign in and download speech recognition. After that, shepetal needs no internet to dictate.' },
      { title: 'Your license, offline', text: 'A lifetime license works offline with no limit. During the trial, shepetal checks your license at least once a week.' },
      { title: 'Meetings too', text: 'Meetings, transcribed on your Mac. The meeting reminder appears when a call starts.' },
    ],
    columns: ['processing', 'offline'],
    others:
      'Superwhisper and MacWhisper also work offline, with on-device processing. Apple Dictation works offline on a Mac with Apple silicon, for supported languages. Wispr Flow needs an internet connection to dictate.',
    updated: ASOF,
  },
  {
    slug: 'private-dictation-mac',
    label: 'Private dictation',
    ref: 'seo-private',
    title: 'Private dictation on Mac: on-device or cloud',
    description: 'Which Mac dictation apps keep your voice on your Mac? shepetal, Wispr Flow, Superwhisper, MacWhisper and Apple Dictation, with each fact linked to its source.',
    h1: 'Keep your voice on your Mac.',
    lede: '100% private. Your data is yours. shepetal processes your voice on your Mac, and it never leaves it.',
    sections: [
      { title: 'What stays on your Mac', text: 'Your voice is processed on your Mac. Your recordings and history stay in your user folder until you delete them.' },
      { title: 'What leaves it', text: 'To sign in, shepetal uses your Google email, and it checks your license once a day. shepetal itself sends no text and no analytics.' },
      { title: 'Your words go where you put them', text: 'Into the app you dictate into. Works in every app.' },
    ],
    columns: ['processing', 'offline'],
    others:
      'MacWhisper and Superwhisper offer on-device processing, and cloud services as an option. Apple Dictation processes on a Mac with Apple silicon, for supported languages. Wispr Flow processes in the cloud.',
    updated: ASOF,
  },
];

export const comparison = (slug: string): Comparison => {
  const c = COMPARISONS.find((x) => x.slug === slug);
  if (!c) throw new Error(`no comparison ${slug}`);
  return c;
};

export const guide = (slug: string): Guide => {
  const g = GUIDES.find((x) => x.slug === slug);
  if (!g) throw new Error(`no guide ${slug}`);
  return g;
};

export const comparePath = (slug: string) => `/compare/${slug}`;
export const guidePath = (slug: string) => `/${slug}`;
export const compareRef = (slug: string) => `compare-${slug}`;

/** Every page here, in the footer's order: the four apps, then the two guides. */
export const COMPARE_LINKS = [
  ...COMPARISONS.map((c) => ({ href: comparePath(c.slug), label: c.name, updated: c.updated })),
  ...GUIDES.map((g) => ({ href: guidePath(g.slug), label: g.label, updated: g.updated })),
];

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

/** "2026-10-22" as "22 October 2026". */
export const formatDate = (iso: string) => {
  const [y, m, d] = iso.split('-').map(Number);
  return `${d} ${MONTHS[m - 1]} ${y}`;
};

/** A source link's text: the site, without www. */
export const sourceLabel = (url: string) => new URL(url).hostname.replace(/^www\./, '');

/** Canonical URL, Open Graph and the X card, with the landing page's link preview. */
function metadataFor(path: string, title: string, description: string): Metadata {
  const ogTitle = `${title} - shepetal`;
  const images = [ogImage('home')];
  return {
    title,
    description,
    alternates: { canonical: path },
    openGraph: { title: ogTitle, description, url: path, siteName: 'shepetal', type: 'website', locale: 'en_US', images },
    twitter: { card: 'summary_large_image', title: ogTitle, description, images },
  };
}

export const comparisonMetadata = (slug: string) => {
  const c = comparison(slug);
  return metadataFor(comparePath(slug), c.title, c.description);
};

export const guideMetadata = (slug: string) => {
  const g = guide(slug);
  return metadataFor(guidePath(slug), g.title, g.description);
};
