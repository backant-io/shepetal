import type { ReactNode } from 'react';

/** One app in the comparisons. Every field is a fact a reader can check on the app's own site (sources in apps.ts). */
export type App = {
  id: AppId;
  name: string;
  /** The app's own homepage. Each article links it once, at the first mention in the text. */
  url: string;
  maker: string;
  platforms: string;
  price: string;
  /** What a new user gets for free: the trial or the free plan. */
  free: string;
  /** Where speech recognition runs. */
  recognition: string;
  offline: string;
  /** What happens to your voice and your text. */
  privacy: string;
  everyApp: string;
  meetings: string;
  /** One line for lists: who the app is for. */
  bestFor: string;
};

export type AppId =
  | 'shepetal'
  | 'wispr'
  | 'superwhisper'
  | 'macwhisper'
  | 'aqua'
  | 'willow'
  | 'voiceink'
  | 'apple'
  | 'dragon'
  | 'spokenly'
  | 'monologue';

export type Section = { id: string; title: string; body: ReactNode };

export type Faq = { q: string; a: string };

export type Article = {
  slug: string;
  /** The page's h1. */
  title: string;
  /** The <title>, 60 characters or fewer, with the keyword first. */
  seoTitle: string;
  /** The meta and link-preview description: 120 to 160 characters, no price (brand: link previews carry no price). */
  description: string;
  /** The search phrase the article is written for. */
  keyword: string;
  kind: 'comparison' | 'ranking' | 'guide';
  /** ISO dates. */
  published: string;
  updated: string;
  /** The lead under the h1. */
  dek: string;
  /** The answer first: two or three sentences for readers who stop here. */
  short: ReactNode;
  /** The apps the article names. The test checks each one's site is linked exactly once. */
  apps: AppId[];
  sections: Section[];
  faq: Faq[];
  related: string[];
  /** For rankings: the apps in ranked order (ItemList in the JSON-LD). */
  ranked?: AppId[];
};
