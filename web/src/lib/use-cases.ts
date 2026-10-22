import type { Metadata } from 'next';
import { ogImage } from './seo';
import { SITE_URL } from './site';

/**
 * The use-case pages at /for/<slug>: one per audience, each a static page (src/app/(site)/for/<slug>/page.tsx) in the
 * sitemap and in the footer's "Made for" list. Plain text only, so the tests read exactly what the page says.
 * Every claim comes from the FAQ or the landing page. No number but the trial, the prices, macOS 14.4 and the 25
 * languages; no model name; no medical claim.
 */
export type UseCase = {
  slug: string;
  /** the footer's "Made for" link */
  label: string;
  /** <title> (before " - shepetal") and the link preview */
  title: string;
  description: string;
  h1: string;
  lede: string;
  scenarios: { title: string; text: string }[];
  facts: string[];
  /** a plain sentence after the scenarios, when the page needs one */
  note?: string;
  /** shown on the page and sent as FAQPage data: only questions the FAQ answers */
  qas?: { q: string; a: string }[];
  updated: string;
};

/** The landing page's trial button (Story.tsx TRY). */
export const TRY = 'Try 30 days free';

export const USE_CASES: UseCase[] = [
  {
    slug: 'developers',
    label: 'Developers',
    title: 'Dictation for developers',
    description: 'Speak commit messages, PR descriptions, code review notes and chat on your Mac. Works in every app. Your voice never leaves your Mac.',
    h1: 'Write the words around the code.',
    lede: 'Commit messages, PR descriptions, review notes and chat, spoken. The key is fn, so your hands stay on the keyboard.',
    scenarios: [
      { title: 'Commit messages', text: 'Say what changed while it is fresh. The words appear in your terminal or in your editor’s commit box.' },
      { title: 'PR descriptions', text: 'Explain the why in full sentences, in the browser, before you ask for review.' },
      { title: 'Code review notes', text: 'Read the diff, press the key and say what you see. The comment appears in the review box.' },
      { title: 'Chat with your team', text: 'Answer a question without leaving the keyboard. Chat is one more app, and shepetal works in all of them.' },
    ],
    facts: [
      'Works in every app. Your editor, the terminal, the browser and chat.',
      'Instant. 4x faster than typing.',
      '100% private. Your data is yours. Your voice never leaves your Mac.',
      'Works offline.',
    ],
    updated: '2026-10-22',
  },
  {
    slug: 'writers',
    label: 'Writers',
    title: 'Dictation for writers',
    description: 'Speak the first draft on your Mac, in the app you write in. 25 European languages. Your voice never leaves your Mac.',
    h1: 'Say the draft. Shape it after.',
    lede: 'Get the first version down as fast as you can say it. Your words appear in the app you write in.',
    scenarios: [
      { title: 'The first draft', text: 'Talk through the piece in your editor. Then edit with the keyboard, as you always have.' },
      { title: 'The idea that arrives mid-sentence', text: 'Say it into a note and go back to the page. The note is there when you need it.' },
      { title: 'Long replies', text: 'Letters, emails and messages to editors, spoken in the app you send them from.' },
      { title: 'On the move', text: 'Works offline. Write on a plane, on a train, in a cabin with no signal.' },
    ],
    facts: [
      'Instant. 4x faster than typing.',
      'Works in every app.',
      '100% private. Your data is yours. Your voice never leaves your Mac.',
      'Works offline.',
    ],
    qas: [
      {
        q: 'Which languages does it understand?',
        a: '25 European languages, among them English, German, French, Spanish, Italian, Portuguese, Dutch, Polish, Ukrainian and Slovene. Automatic picks the one you speak, or choose yours under Languages in the menu.',
      },
    ],
    updated: '2026-10-22',
  },
  {
    slug: 'rsi',
    label: 'RSI',
    title: 'Dictation for RSI and wrist pain',
    description: 'Type less on your Mac: speak, and your words appear wherever your cursor is. One key, every app. Your voice never leaves your Mac.',
    h1: 'Type less.',
    lede: 'When typing hurts, speak instead. Press one key, and your words appear wherever your cursor is.',
    scenarios: [
      { title: 'The long email', text: 'Say the long reply instead of typing it. Then fix a word or two by hand.' },
      { title: 'A day of messages', text: 'Chat, notes and tickets, each one spoken. Works in every app.' },
      { title: 'Documents', text: 'Speak a page in your editor, then read it over.' },
      { title: 'One key', text: 'shepetal needs one key, fn. No key combination to learn.' },
    ],
    facts: ['Works in every app.', 'Instant. 4x faster than typing.', '100% private. Your data is yours.', 'Works offline.'],
    note: 'shepetal is a dictation app, not a medical device. For pain, talk to a doctor.',
    updated: '2026-10-22',
  },
  {
    slug: 'adhd',
    label: 'ADHD',
    title: 'Dictation for ADHD',
    description: 'Get thoughts down the moment you have them. Press one key on your Mac and speak. Works in every app, and your voice never leaves your Mac.',
    h1: 'Catch the thought before it goes.',
    lede: 'Press one key and say it. Your words appear wherever your cursor is.',
    scenarios: [
      { title: 'The idea in the middle of something', text: 'Open a note, press the key, say it, go back to what you were doing.' },
      { title: 'The message you keep putting off', text: 'Say it the way you would say it to a friend. Then it is written, and you can send it.' },
      { title: 'Everything on your mind', text: 'Say it all into one document. Sort it later.' },
      { title: 'The list', text: 'Speak the tasks into your to-do app. shepetal works in every app.' },
    ],
    facts: ['Instant.', 'Works in every app.', '100% private. Your data is yours. Your voice never leaves your Mac.', 'Works offline.'],
    updated: '2026-10-22',
  },
  {
    slug: 'privacy',
    label: 'Private work',
    title: 'Private dictation for Mac',
    description: 'Dictation that runs on your Mac: your voice never leaves it, and it works offline. 100% private. Your data is yours.',
    h1: 'Your voice stays on your Mac.',
    lede: 'Speech recognition runs on your Mac and needs no internet. 100% private. Your data is yours.',
    scenarios: [
      { title: 'Work under NDA', text: 'Client names and figures are recognized on your Mac. shepetal itself sends no text.' },
      { title: 'Personal notes', text: 'Your recordings and history stay on your Mac, in your user folder, until you delete them.' },
      { title: 'No signal', text: 'Works offline. Once it is set up, dictate on a plane or a train.' },
      { title: 'Your words go where you put them', text: 'Into the app you dictate into, and into the history on your Mac.' },
    ],
    facts: [
      '100% private. Your data is yours.',
      'Works offline.',
      'shepetal itself sends no text and no analytics.',
      'To sign in it uses your Google email, and it checks your license once a day.',
    ],
    qas: [
      {
        q: 'Does my voice leave my Mac?',
        a: 'No. Your voice never leaves your Mac. Speech recognition runs on your Mac, and your recordings and history stay there. Your words go where you put them: into the app you dictate into. shepetal itself sends no text and no analytics. To sign in it uses your Google email, and it checks your license once a day.',
      },
      {
        q: 'Does it work offline?',
        a: 'Speech recognition needs no internet. You are online once to set up: you sign in, and you download speech recognition. After that you can dictate on a plane. A lifetime license works offline with no limit; during the trial, shepetal checks your license at least once a week.',
      },
    ],
    updated: '2026-10-22',
  },
  {
    slug: 'meetings',
    label: 'Meetings',
    title: 'Meeting transcription on your Mac',
    description: 'Meetings, transcribed on your Mac. The meeting reminder appears when a call starts. Your voice never leaves your Mac.',
    h1: 'Meetings, transcribed on your Mac.',
    lede: 'When a call starts, the meeting reminder appears. Press Record, and the call is transcribed on your Mac.',
    scenarios: [
      { title: 'The call you need notes from', text: 'Talk and listen. Read the transcript after.' },
      { title: 'Calls with clients', text: 'The recording and the transcript stay on your Mac. No bot joins the call.' },
      { title: 'The follow-up', text: 'Write the summary email with the transcript open beside it, by voice, in any app.' },
      { title: 'Ask first', text: 'Recording a call? Tell the people on it before you press Record.' },
    ],
    facts: [
      'Meetings, transcribed on your Mac.',
      '100% private. Your data is yours.',
      'Your recordings and history stay on your Mac, in your user folder.',
      'Works in every app. Write the follow-up by voice.',
    ],
    updated: '2026-10-22',
  },
];

export const useCase = (slug: string): UseCase => {
  const u = USE_CASES.find((x) => x.slug === slug);
  if (!u) throw new Error(`no use case ${slug}`);
  return u;
};

export const useCasePath = (slug: string) => `/for/${slug}`;

/** Canonical URL, Open Graph and the X card, with the landing page's link preview. */
export function useCaseMetadata(slug: string): Metadata {
  const u = useCase(slug);
  const path = useCasePath(slug);
  const ogTitle = `${u.title} - shepetal`;
  const images = [ogImage('home')];
  return {
    title: u.title,
    description: u.description,
    alternates: { canonical: path },
    openGraph: { title: ogTitle, description: u.description, url: path, siteName: 'shepetal', type: 'website', locale: 'en_US', images },
    twitter: { card: 'summary_large_image', title: ogTitle, description: u.description, images },
  };
}

/** FAQPage data for the questions the page shows, or null when it shows none. */
export function useCaseFaqJsonLd(slug: string) {
  const u = useCase(slug);
  if (!u.qas?.length) return null;
  return {
    '@context': 'https://schema.org',
    '@type': 'FAQPage',
    url: `${SITE_URL}${useCasePath(slug)}`,
    mainEntity: u.qas.map((x) => ({ '@type': 'Question', name: x.q, acceptedAnswer: { '@type': 'Answer', text: x.a } })),
  };
}
