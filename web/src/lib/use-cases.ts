import type { Metadata } from 'next';
import og from './use-case-og.json';

/**
 * The use-case pages at /for/<slug>: one per audience, each a static page (src/app/(site)/for/<slug>/page.tsx) in the
 * sitemap and in the footer's "Made for" list, with its own link preview (public/og/for-<slug>.jpg, rendered by
 * og/pages.mjs from use-case-og.json). Plain text only, so the tests read exactly what the page says.
 * Marketing copy: the approved claims word for word, one per line, and only what the app does today with its default
 * settings. How it works and what it needs (sign-in, license checks, the Macs it runs on) belong to the FAQ and the
 * Privacy Policy, which the page links to. No model name; no medical claim.
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
  /** "The facts": the approved claims, one per line */
  facts: string[];
  /** a plain sentence after the scenarios, when the page needs one */
  note?: string;
  updated: string;
};

/** The landing page's trial button (Story.tsx TRY). */
export const TRY = 'Try 30 days free';

/** The approved claims, word for word. A page's "The facts" list uses only these. */
export const CLAIMS = [
  '100% private. Your data is yours.',
  'Works offline.',
  'Instant.',
  '4x faster than typing.',
  'Works in every app.',
  'Meetings, transcribed on your Mac.',
] as const;

export const USE_CASES: UseCase[] = [
  {
    slug: 'developers',
    label: 'Developers',
    title: 'Dictation for developers',
    description: 'Speak commit messages, PR descriptions, review notes and chat on your Mac. Works in every app. Your voice never leaves your Mac.',
    h1: 'Say the words that go with the code.',
    lede: 'Commit messages, PR descriptions, review notes and chat, spoken. The key is fn, so your hands stay on the keyboard.',
    scenarios: [
      { title: 'Commit messages', text: 'Say what changed while it is fresh. Your words appear in the terminal or in your editor’s commit box.' },
      { title: 'PR descriptions', text: 'Explain the why in full sentences, right in the browser.' },
      { title: 'Code review notes', text: 'Read the diff and say what you see. Your words appear in the review box.' },
      { title: 'Chat with your team', text: 'Answer a question without leaving the keyboard. Chat is one more app, and shepetal works in all of them.' },
    ],
    facts: ['Works in every app.', 'Instant.', '4x faster than typing.', '100% private. Your data is yours.', 'Works offline.'],
    updated: '2026-10-23',
  },
  {
    slug: 'writers',
    label: 'Writers',
    title: 'Dictation for writers',
    description: 'Speak the first draft on your Mac, in the app you write in. 25 European languages. Your voice never leaves your Mac.',
    h1: 'Say the draft. Shape it after.',
    lede: 'Get the first version down as fast as you can say it. Your words appear in the app you write in.',
    scenarios: [
      { title: 'The first draft', text: 'Talk the piece through in your editor. Then edit with the keyboard, as you always have.' },
      { title: 'The idea that arrives mid-sentence', text: 'Say it into shepetal’s Notes and stay on the page you are writing.' },
      { title: 'Long replies', text: 'Letters, emails and messages to editors, spoken in the app you send them from.' },
      { title: 'In your language', text: '25 European languages, among them English, German, French, Spanish, Italian and Polish.' },
    ],
    facts: ['Instant.', '4x faster than typing.', 'Works in every app.', '100% private. Your data is yours.', 'Works offline.'],
    updated: '2026-10-23',
  },
  {
    slug: 'rsi',
    label: 'RSI',
    title: 'Dictation for RSI and wrist pain',
    description: 'Type less on your Mac: speak, and your words appear wherever your cursor is. One key, every app. Your voice never leaves your Mac.',
    h1: 'Type less.',
    lede: 'Speak instead of typing. Press one key, and your words appear wherever your cursor is.',
    scenarios: [
      { title: 'The long email', text: 'Say the long reply instead of typing it. Then fix a word or two by hand.' },
      { title: 'A day of messages', text: 'Chat, notes and tickets, each one spoken.' },
      { title: 'Documents', text: 'Speak a page in your editor, then read it over.' },
      { title: 'One key', text: 'Dictation needs one key: fn.' },
    ],
    facts: ['Works in every app.', 'Instant.', '4x faster than typing.', '100% private. Your data is yours.', 'Works offline.'],
    note: 'shepetal is a dictation app, not a medical device. If typing hurts, talk to a doctor.',
    updated: '2026-10-23',
  },
  {
    slug: 'adhd',
    label: 'ADHD',
    title: 'Dictation for ADHD',
    description: 'Get thoughts down the moment you have them: one key on your Mac, and your words appear. Works in every app. Your voice never leaves your Mac.',
    h1: 'Catch the thought before it goes.',
    lede: 'Press one key. Your words appear wherever your cursor is.',
    scenarios: [
      { title: 'The idea in the middle of something', text: 'Say it into shepetal’s Notes and carry on with what you were doing.' },
      { title: 'The message you keep putting off', text: 'Say it the way you would say it to a friend. Then it is written, and you can send it.' },
      { title: 'Everything on your mind', text: 'Say it all into one document. Sort it later.' },
      { title: 'The list', text: 'Speak the tasks into your to-do app.' },
    ],
    facts: ['Instant.', 'Works in every app.', '100% private. Your data is yours.', 'Works offline.'],
    note: 'shepetal is a dictation app, not a medical device.',
    updated: '2026-10-23',
  },
  {
    slug: 'privacy',
    label: 'Private work',
    title: 'Private dictation for Mac',
    description: 'Dictation that runs on your Mac: your voice never leaves it, and it works offline. 100% private. Your data is yours.',
    h1: 'Your voice stays on your Mac.',
    lede: 'Speech recognition runs on your Mac. Your voice never leaves it.',
    scenarios: [
      { title: 'Work under NDA', text: 'Client names and figures are recognized on your Mac. shepetal itself sends no text and no analytics.' },
      { title: 'Personal notes', text: 'Your recordings, notes and history stay on your Mac, in your user folder.' },
      { title: 'No signal', text: 'Dictate on a plane, on a train, in a cabin with no signal.' },
      { title: 'Your words go where you put them', text: 'Into the app you dictate into, and into the history on your Mac.' },
    ],
    facts: ['100% private. Your data is yours.', 'Works offline.', 'Works in every app.', 'Meetings, transcribed on your Mac.'],
    updated: '2026-10-23',
  },
  {
    slug: 'meetings',
    label: 'Meetings',
    title: 'Meeting transcription on your Mac',
    description: 'Meetings, transcribed on your Mac. shepetal offers to record when a call starts. Your voice never leaves your Mac.',
    h1: 'Meetings, transcribed on your Mac.',
    lede: 'When a call starts, shepetal offers to record it. Choose Record, and the call is transcribed on your Mac.',
    scenarios: [
      { title: 'The call you need notes from', text: 'Talk and listen. Read the transcript after.' },
      { title: 'Calls with clients', text: 'The recording and the transcript stay on your Mac. No bot joins the call.' },
      { title: 'Your side and theirs', text: 'Your microphone and the call’s sound are both recorded, on your Mac.' },
      { title: 'The follow-up', text: 'Write the follow-up email with the transcript open beside it, by voice, in any app.' },
    ],
    facts: ['Meetings, transcribed on your Mac.', '100% private. Your data is yours.', 'Works in every app.'],
    updated: '2026-10-23',
  },
];

/** The use-case pages' link previews (use-case-og.json), keyed for-<slug>. */
export const USE_CASE_OG = og as Record<string, { path: string; title: string; sub: string }>;

export const useCase = (slug: string): UseCase => {
  const u = USE_CASES.find((x) => x.slug === slug);
  if (!u) throw new Error(`no use case ${slug}`);
  return u;
};

export const useCasePath = (slug: string) => `/for/${slug}`;

/** The page's own link preview, 1200 x 630 (public/og/for-<slug>.jpg). No price and no steps on a preview. */
export function useCaseOgImage(slug: string) {
  const p = USE_CASE_OG[`for-${slug}`];
  if (!p) throw new Error(`no link preview for ${slug}`);
  return { url: `/og/for-${slug}.jpg`, width: 1200, height: 630, type: 'image/jpeg', alt: `shepetal. ${p.title} The orange fn key on a concrete-white ground.` };
}

/** Canonical URL, Open Graph and the X card, with the page's own link preview. */
export function useCaseMetadata(slug: string): Metadata {
  const u = useCase(slug);
  const path = useCasePath(slug);
  const ogTitle = `${u.title} - shepetal`;
  const images = [useCaseOgImage(slug)];
  return {
    title: u.title,
    description: u.description,
    alternates: { canonical: path },
    openGraph: { title: ogTitle, description: u.description, url: path, siteName: 'shepetal', type: 'website', locale: 'en_US', images },
    twitter: { card: 'summary_large_image', title: ogTitle, description: u.description, images },
  };
}
