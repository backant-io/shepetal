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
    description: 'Say your commit messages, PR descriptions and review notes on your Mac and your words appear in the terminal, the editor or the browser.',
    h1: 'shepetal for developers',
    lede: 'Until now you typed every commit message, PR description and review note by hand, and the writing came at the end of the day when you just wanted to be done. You don’t have to do that anymore. We have built shepetal so you can just say it and your words appear in the terminal, the editor or the browser, wherever your cursor is.',
    scenarios: [
      { title: 'Commits', text: 'You say what changed while it is still fresh in your head and the commit message appears in the terminal or in the commit box of your editor.' },
      { title: 'Pull requests', text: 'You explain why you made the change in full sentences, right in the browser, and your reviewer gets the whole story in the description.' },
      { title: 'Reviews', text: 'You read the diff and just say what you see, and your comment appears in the review box.' },
      { title: 'Team chat', text: 'You answer a question from your team right in the chat app, the same way you write a commit message.' },
    ],
    facts: ['Works in every app.', 'Instant.', '4x faster than typing.', '100% private. Your data is yours.', 'Works offline.'],
    updated: '2026-10-23',
  },
  {
    slug: 'writers',
    label: 'Writers',
    title: 'Dictation for writers',
    description: 'Say your first draft on your Mac and your words appear in the app you write in, in 25 European languages, and your voice stays on your Mac.',
    h1: 'shepetal for writers',
    lede: 'Until now the first draft was the slow part, because your thoughts were always a few sentences ahead of your fingers. You don’t have to wait for your hands anymore. We have built shepetal so you can just say the draft and your words appear in the app you write in, as fast as you can say them.',
    scenarios: [
      { title: 'First draft', text: 'You talk the piece through in your editor and then edit it with the keyboard, the same way you always have.' },
      { title: 'Ideas', text: 'When an idea arrives in the middle of a sentence you just say it into shepetal’s Notes and carry on with the page you are writing.' },
      { title: 'Replies', text: 'You just say your letters, emails and messages to your editor in the app you send them from, and read them over before they go out.' },
      { title: 'Your language', text: 'shepetal works in 25 European languages, among them English, German, French, Spanish, Italian and Polish, so you can write in the one you think in.' },
    ],
    facts: ['Instant.', '4x faster than typing.', 'Works in every app.', '100% private. Your data is yours.', 'Works offline.'],
    updated: '2026-10-23',
  },
  {
    slug: 'rsi',
    label: 'RSI',
    title: 'Dictation for RSI and wrist pain',
    description: 'Type less on your Mac: you speak and your words appear wherever your cursor is, in every app, and your voice stays on your Mac.',
    h1: 'shepetal for RSI',
    lede: 'Until now every email, message and document went through your wrists, key by key, all day long. You don’t have to type all of it anymore. We have built shepetal so you can just speak and your words appear wherever your cursor is.',
    scenarios: [
      { title: 'Long emails', text: 'You say the long reply out loud and then fix a word or two by hand before you send it.' },
      { title: 'Messages', text: 'Chat, notes and tickets add up over a day, and you can speak each one of them in the app it belongs in.' },
      { title: 'Documents', text: 'You speak a whole page in your editor and then just read it over and change what you want to change.' },
      { title: 'One key', text: 'Dictation needs a single key, fn, and the rest of the work is done by your voice.' },
    ],
    facts: ['Works in every app.', 'Instant.', '4x faster than typing.', '100% private. Your data is yours.', 'Works offline.'],
    note: 'shepetal is a dictation app, not a medical device. If typing hurts, please go and talk to a doctor.',
    updated: '2026-10-23',
  },
  {
    slug: 'adhd',
    label: 'ADHD',
    title: 'Dictation for ADHD',
    description: 'Get a thought down the moment you have it: you speak on your Mac and your words appear in every app, and your voice stays on your Mac.',
    h1: 'shepetal for ADHD',
    lede: 'Until now a good thought was often gone again by the time you had found the right app and started typing. You don’t have to lose it anymore. We have built shepetal so you can just say it and your words appear wherever your cursor is, right away.',
    scenarios: [
      { title: 'Ideas', text: 'An idea shows up in the middle of something else, so you just say it into shepetal’s Notes and carry on with what you were doing.' },
      { title: 'Messages', text: 'For the message you keep putting off, you say it the way you would say it to a friend, and then it is written and ready to send.' },
      { title: 'Everything else', text: 'You say everything that is on your mind into one document and sort it out later, when you have the time.' },
      { title: 'Lists', text: 'You speak your tasks straight into your to-do app, one after the other, wherever your cursor is.' },
    ],
    facts: ['Instant.', 'Works in every app.', '100% private. Your data is yours.', 'Works offline.'],
    note: 'shepetal is a dictation app, not a medical device.',
    updated: '2026-10-23',
  },
  {
    slug: 'privacy',
    label: 'Private work',
    title: 'Private dictation for Mac',
    description: 'Speech recognition runs on your Mac, so your voice stays on it and dictation works offline. 100% private. Your data is yours.',
    h1: 'shepetal for private work',
    lede: 'If you work with client names, figures and contracts, you think twice before your voice goes anywhere. We have built shepetal so speech recognition runs on your Mac and your voice stays there.',
    scenarios: [
      { title: 'Client work', text: 'Client names and figures are recognized on your Mac, so you can just dictate your notes on work under NDA like anything else.' },
      { title: 'Personal notes', text: 'Your recordings, notes and history are saved in your user folder on your Mac, right next to the rest of your files.' },
      { title: 'Offline', text: 'You can dictate on a plane or on a train with the wifi switched off and your words still appear wherever your cursor is.' },
      { title: 'Your text', text: 'From shepetal your words go to two places: the app you are dictating into and the history on your Mac.' },
    ],
    facts: ['100% private. Your data is yours.', 'Works offline.', 'Works in every app.', 'Meetings, transcribed on your Mac.'],
    updated: '2026-10-23',
  },
  {
    slug: 'meetings',
    label: 'Meetings',
    title: 'Meeting transcription on your Mac',
    description: 'Meetings, transcribed on your Mac. When a call starts, shepetal offers to record it and the call is transcribed on your Mac.',
    h1: 'Meetings, transcribed on your Mac.',
    lede: 'Until now you took notes during the call and listened with half an ear while you were writing. You don’t have to do that anymore. When a call starts shepetal offers to record it, you choose Record and the call is transcribed on your Mac.',
    scenarios: [
      { title: 'Notes', text: 'You just talk and listen, and you read the transcript after the call.' },
      { title: 'Client calls', text: 'shepetal records the call on your Mac, so the people in the call stay the same, and the recording and the transcript stay on your Mac.' },
      { title: 'Both sides', text: 'Your microphone and the sound of the call are both recorded on your Mac, so the transcript has your side and theirs.' },
      { title: 'Follow-up', text: 'You write the follow-up email by voice in any app, with the transcript open next to it.' },
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
