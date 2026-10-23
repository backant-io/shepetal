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
  { key: 'offline', label: 'Offline' },
  { key: 'platforms', label: 'Platforms' },
  { key: 'price', label: 'Price' },
  { key: 'languages', label: 'Languages' },
  { key: 'meetings', label: 'Meetings' },
  { key: 'anyApp', label: 'In any app' },
];

/** The approved claims (brand/voice.md), word for word. On these pages each one stands on a line of its own: a "\n" in
 * any text below starts a new line (Lines in Compare.tsx). */
export const CLAIMS = ['100% private. Your data is yours.', 'Works offline.', 'Instant.', '4x faster than typing.', 'Works in every app.', 'Meetings, transcribed on your Mac.'];

/**
 * shepetal's side of every table, each line true of the Mac app in Sources/ and the prices in web/: speech recognition on
 * the Mac (Speech.swift), one download of it and no other network use, macOS 14 (Package.swift, make-app.sh), Parakeet's
 * 25 European languages on Apple silicon and English on Intel (ModelTier.swift), paste with the clipboard as the fallback
 * (Inserter.swift, SecureInput.swift), and no meeting transcription in the app yet.
 */
export const SHEPETAL: Record<RowKey, string> = {
  processing: 'On your Mac, and your voice stays there.',
  offline: 'Works offline.\nYou go online once, to download speech recognition.',
  platforms: 'Mac, with macOS 14 or later.',
  price: '$23.99 once. Yours forever.\n$0.99 a month.\nYou can try it free for 30 days.',
  languages: '25 European languages on a Mac with Apple silicon, and English on an Intel Mac.',
  meetings: 'Not in shepetal yet.',
  anyApp: 'Works in every app.\nWhen an app blocks paste, your words wait for you on the clipboard.',
};

/** A fact about another app: what its own public page says, the page, and the day it was read. */
export type Fact = { text: string; sources: string[]; asOf: string };

/** A line of "which to pick"; `source` when it states something the table does not. */
export type Pick = { text: string; source?: string; asOf?: string };

/** Pick shepetal for on-device processing: the same line on every page. */
const ON_DEVICE = 'You want every dictation processed on your Mac, which is the only way shepetal works.';

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
    description: 'See how shepetal and Wispr Flow compare on where your voice is processed, offline use, platforms, price, languages and meetings, with a source for each fact.',
    h1: 'shepetal or Wispr Flow',
    lede: 'You want to speak and have your words land in the app you are working in, and both apps do that for you. shepetal turns your voice into text on your Mac, and Wispr Flow sends it to the cloud and transcribes it there.',
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
      { text: 'You also dictate on Windows, iOS or Android and want the same app there as on your Mac.' },
      { text: 'You speak a language outside the 25 European languages shepetal knows on a Mac with Apple silicon.' },
      { text: 'You want a free plan you can keep using, or plans for your team.' },
    ],
    pickShepetal: [
      { text: 'You want your voice to stay on your Mac the whole time.\n100% private. Your data is yours.' },
      { text: 'You dictate in places where you have no internet, like on a plane or a train.\nWorks offline.' },
      { text: 'You want to pay once and keep it.\n$23.99 once. Yours forever.' },
    ],
    updated: ASOF,
  },
  {
    slug: 'superwhisper',
    name: 'Superwhisper',
    title: 'shepetal vs Superwhisper',
    description: 'See how shepetal and Superwhisper compare on where your voice is processed, offline use, platforms, price, languages and meetings, with a source for each fact.',
    h1: 'shepetal or Superwhisper',
    lede: 'Both apps put your words into the app you are working in and both work offline. shepetal processes your voice on your Mac every time, and Superwhisper lets you choose between your device and the cloud.',
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
      { text: 'You want the cloud as an option for processing.' },
      { text: 'You also dictate on Windows, iOS or Android and want the same app there as on your Mac.' },
      { text: 'You want a free plan you can keep using.' },
    ],
    pickShepetal: [
      { text: ON_DEVICE },
      { text: 'You want to pay by the month.\n$0.99 a month.' },
      { text: 'You want to pay once and keep it.\n$23.99 once. Yours forever.' },
    ],
    updated: ASOF,
  },
  {
    slug: 'macwhisper',
    name: 'MacWhisper',
    title: 'shepetal vs MacWhisper',
    description: 'See how shepetal and MacWhisper compare on where your voice is processed, offline use, platforms, price, languages and meetings, with a source for each fact.',
    h1: 'shepetal or MacWhisper',
    lede: 'Both apps process your voice on your Mac. MacWhisper also transcribes files and meetings, and shepetal is made for dictating into whatever app you are working in.',
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
      { text: 'You also want to transcribe recordings you already have.', source: MACWHISPER, asOf: ASOF },
      { text: 'You want to connect remote services for processing.' },
      { text: 'You want a free version you can keep using.' },
    ],
    pickShepetal: [
      { text: ON_DEVICE },
      { text: 'You want to choose between paying once and paying by the month.\n$23.99 once. Yours forever.\n$0.99 a month.' },
    ],
    updated: ASOF,
  },
  {
    slug: 'apple-dictation',
    name: 'Apple Dictation',
    title: 'shepetal vs Apple Dictation',
    description: 'See how shepetal and Apple Dictation compare on where your voice is processed, offline use, platforms, languages and which apps it works in, each with a source.',
    h1: 'shepetal or Apple Dictation',
    lede: 'Apple Dictation comes with macOS and works anywhere you can type, so you already have it on your Mac. shepetal also puts your words into any app you type in, and it processes every dictation on your Mac.',
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
      { text: 'You want to use what is already on your Mac, because Apple Dictation is part of macOS.' },
      { text: 'You also dictate on your iPhone and want the same dictation there.' },
    ],
    pickShepetal: [
      { text: ON_DEVICE },
      { text: 'You want to keep the recording of what you said on your Mac, next to the text it became.' },
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
    description: 'Dictate with no internet, because shepetal processes speech on your Mac, and see how Wispr Flow, Superwhisper, MacWhisper and Apple Dictation compare.',
    h1: 'Dictate offline',
    lede: 'Works offline.\nYou are on a plane or a train with no signal and you still want to answer that email. shepetal recognizes your speech on your Mac, so you just keep dictating.',
    sections: [
      { title: 'Online once', text: 'shepetal downloads speech recognition once, and after that you can dictate with no internet at all.' },
    ],
    columns: ['processing', 'offline'],
    others:
      'Superwhisper and MacWhisper also work offline when they process on your device. Apple’s guide for macOS Sonoma 14 says Apple Dictation works offline on a Mac with Apple silicon for supported languages, and Wispr Flow transcribes in the cloud.',
    updated: ASOF,
  },
  {
    slug: 'private-dictation-mac',
    label: 'Private dictation',
    ref: 'seo-private',
    title: 'Private dictation on Mac: on-device or cloud',
    description: 'See which Mac dictation apps keep your voice on your Mac: shepetal, Wispr Flow, Superwhisper, MacWhisper and Apple Dictation, each fact linked to its source.',
    h1: 'Keep your voice on your Mac',
    lede: '100% private. Your data is yours.\nYou dictate things that are private to you, and shepetal processes your voice on your Mac, where it stays.',
    sections: [
      { title: 'On your Mac', text: 'Your voice is processed on your Mac, and your recordings and history stay in your user folder. If you choose “Delete recordings after 24 hours”, shepetal takes care of that for you.' },
      { title: 'Online once', text: 'shepetal goes online once, to download speech recognition, and that is the only time it uses the internet.' },
      { title: 'Your words', text: 'Your words land in the app you are dictating into.\nWorks in every app.' },
    ],
    columns: ['processing', 'offline'],
    others:
      'MacWhisper and Superwhisper process on your device and give you remote or cloud processing as an option. Apple Dictation processes on your Mac or on Apple’s servers and Keyboard Settings show you which one, and Wispr Flow transcribes in the cloud.',
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
