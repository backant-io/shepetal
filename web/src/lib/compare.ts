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
export type RowKey = 'processing' | 'offline' | 'platforms' | 'price' | 'languages' | 'meetings' | 'anyApp';

export const ROWS: { key: RowKey; label: string }[] = [
  { key: 'processing', label: 'On-device or cloud' },
  { key: 'offline', label: 'Offline use' },
  { key: 'platforms', label: 'Platforms' },
  { key: 'price', label: 'Pricing' },
  { key: 'languages', label: 'Languages' },
  { key: 'meetings', label: 'Meeting transcription' },
  { key: 'anyApp', label: 'Works in any app' },
];

/**
 * shepetal's side of every table, each line true of the Mac app in Sources/ and the prices in web/: speech recognition on
 * the Mac (Speech.swift), one download of it and no other network use, macOS 14 (Package.swift, make-app.sh), Parakeet's
 * 25 European languages on Apple silicon and English on Intel (ModelTier.swift), paste with the clipboard as the fallback
 * (Inserter.swift, SecureInput.swift), and no meeting transcription in the app yet.
 */
export const SHEPETAL: Record<RowKey, string> = {
  processing: 'On-device processing. Your voice never leaves your Mac.',
  offline: 'Works offline. Online once, to download speech recognition.',
  platforms: 'Mac. macOS 14 or later.',
  price: '$23.99 once. Yours forever. Or $0.99 a month. 30 days free.',
  languages: '25 European languages on a Mac with Apple silicon. English on an Intel Mac.',
  meetings: 'No.',
  anyApp: 'Works in every app. Where an app blocks paste, your words wait on the clipboard.',
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
  /** a row with no fact its own pages state is left out of the table */
  facts: Partial<Record<RowKey, Fact>>;
  pickOther: Pick[];
  pickShepetal: Pick[];
  updated: string;
};

/** The landing page's trial button (Story.tsx TRY). */
export const TRY = 'Try 30 days free';

/** The day every source below was read again. A fact changes with its source: read the page, then change the text and this date. */
const ASOF = '2026-10-23';

const WISPR = {
  pricing: 'https://wisprflow.ai/pricing',
  privacy: 'https://wisprflow.ai/privacy',
};
const SUPERWHISPER = {
  home: 'https://superwhisper.com',
  intro: 'https://superwhisper.com/docs/get-started/introduction',
  plans: 'https://superwhisper.com/docs/billing/plans',
  meetings: 'https://superwhisper.com/docs/meetings/overview',
};
const MACWHISPER = 'https://www.macwhisper.com';
const APPLE = {
  dictation: 'https://support.apple.com/guide/mac-help/use-dictation-mh40584/mac',
  sonoma: 'https://support.apple.com/guide/mac-help/use-dictation-mh40584/14.0/mac/14.0',
  privacy: 'https://www.apple.com/legal/privacy/data/en/ask-siri-dictation/',
  iphone: 'https://support.apple.com/guide/iphone/dictate-text-iph2c0651d2/ios',
  languages: 'https://www.apple.com/macos/feature-availability/',
};

const fact = (text: string, ...sources: string[]): Fact => ({ text, sources, asOf: ASOF });

export const COMPARISONS: Comparison[] = [
  {
    slug: 'wispr-flow',
    name: 'Wispr Flow',
    title: 'shepetal vs Wispr Flow',
    description: 'shepetal and Wispr Flow side by side: on-device or cloud processing, offline use, platforms, prices, languages and meetings, each fact with its source.',
    h1: 'shepetal or Wispr Flow.',
    lede: 'Both put your words in any app. shepetal processes your voice on your Mac. Wispr Flow processes it in the cloud.',
    facts: {
      processing: fact('In the cloud. Its privacy page: “Transcription always happens in the cloud.”', WISPR.privacy),
      offline: fact('No offline transcription. Its privacy page says each dictation is sent to its servers and transcribed there.', WISPR.privacy),
      platforms: fact('Dictation on Mac, Windows, iOS and Android.', WISPR.pricing),
      price: fact('Free: $0/mo, with 2,000 words a week on desktop. Pro: $15/user/mo billed monthly, or $12/user/mo billed annually. Growth and Enterprise plans for teams.', WISPR.pricing),
      languages: fact('100+ languages.', WISPR.pricing),
      meetings: fact('Yes. Its Notetaker, for meetings and voice memos, runs on Mac and Windows.', WISPR.pricing),
      anyApp: fact('Yes. Its pricing page: “Speech-to-text in any app.”', WISPR.pricing),
    },
    pickOther: [
      { text: 'You dictate on Windows, iOS or Android as well as on your Mac.' },
      { text: 'You speak a language outside shepetal’s 25 European languages.' },
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
    description: 'shepetal and Superwhisper side by side: on-device or cloud processing, offline use, platforms, prices, languages and meetings, each fact with its source.',
    h1: 'shepetal or Superwhisper.',
    lede: 'Both work in any app, and both work offline. shepetal processes on your Mac only. Superwhisper also offers cloud processing.',
    facts: {
      processing: fact('On your device or in the cloud, your choice. Its docs say that with on-device processing, nothing you say leaves your device.', SUPERWHISPER.intro),
      offline: fact('Yes. Its docs say on-device transcription works without an internet connection, and other processing of your text needs the internet.', SUPERWHISPER.intro),
      platforms: fact('macOS, Windows, iOS and Android.', SUPERWHISPER.intro),
      price: fact('Free plan. Pro: $8.49/month, $84.99/year or $249.99 once.', SUPERWHISPER.plans),
      languages: fact('100+ languages.', SUPERWHISPER.intro),
      meetings: fact('Yes, on macOS, with Pro. It records calls with no bot in the call.', SUPERWHISPER.meetings, SUPERWHISPER.plans),
      anyApp: fact('Yes. Its docs: “clean, formatted text in any app.”', SUPERWHISPER.intro),
    },
    pickOther: [
      { text: 'You want cloud processing as an option.' },
      { text: 'You dictate on Windows, iOS or Android as well as on your Mac.' },
      { text: 'You want a free plan to keep.' },
    ],
    pickShepetal: [
      { text: 'You want on-device processing and nothing else. shepetal has no cloud processing.' },
      { text: 'You want to pay by the month. $0.99 a month.' },
      { text: 'You want to pay once. $23.99 once. Yours forever.' },
    ],
    updated: ASOF,
  },
  {
    slug: 'macwhisper',
    name: 'MacWhisper',
    title: 'shepetal vs MacWhisper',
    description: 'shepetal and MacWhisper side by side: on-device or cloud processing, offline use, platforms, prices, languages and meetings, each fact with its source.',
    h1: 'shepetal or MacWhisper.',
    lede: 'Both process your voice on your Mac. MacWhisper also transcribes files and meetings. shepetal is made for dictation in every app.',
    facts: {
      processing: fact('On your Mac, or in the cloud with services you connect.', MACWHISPER),
      offline: fact('Yes. Its site: “Process sensitive content locally without data ever leaving your Mac.”', MACWHISPER),
      platforms: fact('Mac.', MACWHISPER),
      price: fact('Free: €0 / month. Pro: €64 / license, paid once, with lifetime updates.', MACWHISPER),
      languages: fact('100 languages.', MACWHISPER),
      meetings: fact('Yes. It records online meetings, with no bots joining.', MACWHISPER),
      anyApp: fact('Yes. Its site: dictation “lets you use your voice in any app.”', MACWHISPER),
    },
    pickOther: [
      { text: 'You transcribe recorded files as well as dictate.', source: MACWHISPER, asOf: ASOF },
      { text: 'You want remote services as an option.' },
      { text: 'You want a free version to keep.' },
    ],
    pickShepetal: [
      { text: 'You want on-device processing and nothing else. shepetal has no cloud processing.' },
      { text: 'You want to choose between paying once and $0.99 a month.' },
    ],
    updated: ASOF,
  },
  {
    slug: 'apple-dictation',
    name: 'Apple Dictation',
    title: 'shepetal vs Apple Dictation',
    description: 'shepetal and Apple Dictation side by side: on-device or server processing, offline use, platforms, languages and where it works, each fact with its source.',
    h1: 'shepetal or Apple Dictation.',
    lede: 'Apple Dictation is part of macOS, and it works anywhere you type. shepetal processes every request on your Mac.',
    facts: {
      processing: fact(
        'On your Mac or on Apple’s servers. Its privacy page says Keyboard Settings show whether dictation is processed on your device; otherwise, Apple’s servers process it.',
        APPLE.privacy,
        APPLE.dictation,
      ),
      offline: fact('On a Mac with Apple silicon, for supported languages, says Apple’s guide for macOS Sonoma 14.', APPLE.sonoma),
      platforms: fact('Part of macOS and iOS.', APPLE.dictation, APPLE.iphone),
      price: fact('Part of macOS, turned on in System Settings.', APPLE.dictation),
      languages: fact('The languages on Apple’s macOS Feature Availability page.', APPLE.languages),
      anyApp: fact('Yes. Its guide: “anywhere you can type it.”', APPLE.dictation),
    },
    pickOther: [
      { text: 'You want nothing to install. It is part of macOS.' },
      { text: 'You dictate on your iPhone too.' },
    ],
    pickShepetal: [
      { text: 'You want every request processed on your Mac. shepetal has no cloud processing.' },
      { text: 'You want the recording of what you said kept on your Mac, next to its text.' },
    ],
    updated: ASOF,
  },
];

/** Every fact about another app with its sources, in table order: the sources list on each page and the PR's table. */
export const factsOf = (c: Comparison) =>
  ROWS.flatMap((r) => {
    const f = c.facts[r.key];
    return f ? [{ key: r.key, label: r.label, ...f }] : [];
  });

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
      { title: 'Online once', text: 'shepetal downloads speech recognition once. After that, it needs no internet to dictate.' },
    ],
    columns: ['processing', 'offline'],
    others:
      'Superwhisper and MacWhisper also work offline, with on-device processing. Apple’s guide for macOS Sonoma 14 says Apple Dictation works offline on a Mac with Apple silicon, for supported languages. Wispr Flow transcribes in the cloud.',
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
      { title: 'What stays on your Mac', text: 'Your voice is processed on your Mac. Your recordings and history stay in your user folder. Recordings can be deleted after 24 hours, if you choose.' },
      { title: 'What leaves it', text: 'shepetal downloads speech recognition once. It sends no voice, no text and no analytics.' },
      { title: 'Your words go where you put them', text: 'Into the app you dictate into. Works in every app.' },
    ],
    columns: ['processing', 'offline'],
    others:
      'MacWhisper and Superwhisper offer on-device processing, with remote or cloud processing as an option. Apple Dictation processes on your Mac or on Apple’s servers, and Keyboard Settings show which. Wispr Flow transcribes in the cloud.',
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
