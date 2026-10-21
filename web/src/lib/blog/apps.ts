import type { App, AppId } from './types';

/*
 * The facts behind every table and ranked entry on the blog, checked on each app's own pages on October 21, 2026.
 * The sources, one per fact, are in the comments. When a vendor's pages disagree, the table says only what all of
 * them agree on, or what the newest page says. Recheck every source before changing the `updated` date of an article.
 * Prices are the vendor's web prices in its own currency; app store prices differ.
 */
export const APPS: Record<AppId, App> = {
  shepetal: {
    id: 'shepetal',
    name: 'shepetal',
    url: 'https://shepetal.backant.io',
    maker: 'Pavel Hegler, Backant Inc.',
    platforms: 'Mac',
    price: '$4.99 once, with updates',
    free: 'A 30-day trial',
    recognition: 'On your Mac',
    offline: 'Yes',
    privacy: 'Stays on your Mac',
    everyApp: 'Every app, terminals and code editors included',
    meetings: 'Transcribed on your Mac, with a summary and action items',
    bestFor: 'Instant, private dictation in every app on your Mac',
  },
  wispr: {
    // wisprflow.ai/pricing; docs.wisprflow.ai "Flow plans and what's included"; wisprflow.ai/data-controls;
    // wisprflow.ai/privacy; docs "How to install Wispr Flow on Mac"; wisprflow.ai/whats-new (Notetaker, Aug and Sep 2026).
    id: 'wispr',
    name: 'Wispr Flow',
    url: 'https://wisprflow.ai/',
    maker: 'Wispr AI, Inc.',
    platforms: 'Mac, Windows, iPhone, Android',
    price: '$15 a month, or $144 a year',
    free: '2,000 words a week on Mac and Windows, and a 14-day Pro trial',
    recognition: 'In the cloud',
    offline: 'No',
    privacy: 'Sent to Wispr’s servers for every dictation, and deleted after transcription unless cloud storage is on',
    everyApp: 'Every app on Mac and Windows',
    meetings: 'Notetaker on Mac and Windows, stored in Wispr’s cloud',
    bestFor: 'Dictation on every device you own, with editing in the cloud',
  },
  superwhisper: {
    // superwhisper.com; superwhisper.com/docs/billing/plans; docs/security/sensitive-data; docs/get-started/quickstart;
    // superwhisper.com/changelog (macOS 14 minimum, 3,000-word trial, Meetings 3.0).
    id: 'superwhisper',
    name: 'Superwhisper',
    url: 'https://superwhisper.com/',
    maker: 'SuperUltra, Inc.',
    platforms: 'Mac, Windows, iPhone, Android',
    price: '$8.49 a month, $84.99 a year or $249.99 once',
    free: 'Free plan with unlimited on-device dictation, and 3,000 words of Pro',
    recognition: 'On your device or in the cloud; a new setup starts in the cloud',
    offline: 'Yes, in an on-device mode',
    privacy: 'Kept on your device in on-device modes; cloud modes send audio to providers with zero retention',
    everyApp: 'Every app',
    meetings: 'On Mac, with Pro',
    bestFor: 'Tuning modes, prompts and engines for every kind of text',
  },
  macwhisper: {
    // www.macwhisper.com (plans, offline, meetings, 100 languages); docs.macwhisper.com articles 14 and 40;
    // www.macwhisper.com/legal/privacy-policy.
    id: 'macwhisper',
    name: 'MacWhisper',
    url: 'https://www.macwhisper.com/',
    maker: 'Good Snooze (Jordi Bruin)',
    platforms: 'Mac',
    price: '€64 once for Pro',
    free: 'Free version, with system-wide dictation',
    recognition: 'On your Mac, with optional cloud services on your own keys',
    offline: 'Yes',
    privacy: 'Stays on your Mac unless you connect a cloud service',
    everyApp: 'Every app, in the version from its website',
    meetings: 'Records Zoom, Teams and more on your Mac, with Pro',
    bestFor: 'Transcribing files, recordings and meetings',
  },
  aqua: {
    // aquavoice.com/pricing; aquavoice.com/mac FAQ ("there is no offline mode"); aquavoice.com/info/privacy;
    // aquavoice.com/info/faq; aquavoice.com/changelog (Android, October 6, 2026).
    id: 'aqua',
    name: 'Aqua Voice',
    url: 'https://aquavoice.com/',
    maker: 'Aqua Voice, Inc.',
    platforms: 'Mac, Windows, iPhone, Android',
    price: '$10 a month, or $96 a year for Pro',
    free: '1,000 words to try',
    recognition: 'In the cloud',
    offline: 'No, on Mac and Windows',
    privacy: 'Sent to Aqua’s servers; with Privacy Mode on, nothing is stored there',
    everyApp: 'Every app on Mac and Windows',
    meetings: 'Not offered',
    bestFor: 'Edited, polished prose and tools for developers',
  },
  willow: {
    // willowvoice.com; willowvoice.com/pricing; willowvoice.com/privacy-policy (Private Mode default, opt-in training);
    // willowvoice.com/blog/best-offline-speech-to-text-tools (offline mode on Mac and iOS only).
    id: 'willow',
    name: 'Willow',
    url: 'https://willowvoice.com/',
    maker: 'Willow Care, Inc.',
    platforms: 'Mac, Windows, iPhone',
    price: '$15 a month, or $12 a month billed yearly',
    free: 'Free plan on a lighter speech engine',
    recognition: 'In the cloud, with an offline mode on Mac and iPhone',
    offline: 'Yes on Mac and iPhone, in offline mode',
    privacy: 'Private Mode is on from the start: audio and text are not kept, and training is opt-in',
    everyApp: 'Every app on Mac and Windows',
    meetings: 'Not on its product pages',
    bestFor: 'Quick replies in email and chat',
  },
  voiceink: {
    // tryvoiceink.com/pricing (one-time plans, Apple silicon, macOS 14.4); tryvoiceink.com/privacy (local by default);
    // tryvoiceink.com/docs/license-management (7-day trial); github.com/Beingpax/VoiceInk (GPL v3).
    id: 'voiceink',
    name: 'VoiceInk',
    url: 'https://tryvoiceink.com/',
    maker: 'Prakash Joshi',
    platforms: 'Mac with Apple silicon, and an iPhone app in beta',
    price: '$25 once for one Mac, $49 for three',
    free: 'A 7-day trial, and open source code to build yourself',
    recognition: 'On your Mac by default; cloud providers on your own key',
    offline: 'Yes, with its local engines',
    privacy: 'Stays on your Mac unless you connect a cloud provider',
    everyApp: 'Every app',
    meetings: 'Not offered',
    bestFor: 'Local dictation with deep settings and open source code',
  },
  apple: {
    // support.apple.com/guide/mac-help/use-dictation-mh40584/mac (any length, 30 s of silence, shortcut, every app);
    // apple.com/macos/feature-availability (on-device languages); apple.com/legal/privacy/data/en/ask-siri-dictation.
    id: 'apple',
    name: 'Apple Dictation',
    url: 'https://support.apple.com/guide/mac-help/use-dictation-mh40584/mac',
    maker: 'Apple',
    platforms: 'Built into Mac, iPhone and iPad',
    price: 'Free',
    free: 'Built in',
    recognition: 'On your Mac for many languages, on Apple’s servers for the rest',
    offline: 'Yes, in the languages it runs on the Mac',
    privacy: 'On-device languages stay on the Mac; server dictation goes to Apple',
    everyApp: 'Every app',
    meetings: 'Not offered',
    bestFor: 'Short notes and messages with nothing to install',
  },
  dragon: {
    // dragon.nuance.com/en-us/dragon-professional (Windows, "Contact us"); the v16 data sheet (internet for download
    // and activation only); Nuance's end-of-life notice for Dragon for Mac (October 22, 2018); the Dragon Anywhere
    // App Store listing (no sales or renewals from July 1, 2026).
    id: 'dragon',
    name: 'Dragon',
    url: 'https://dragon.nuance.com/en-us/dragon',
    maker: 'Nuance, a Microsoft company',
    platforms: 'Windows. Dragon for Mac ended in 2018',
    price: 'Sold through Nuance sales and resellers, with no public price',
    free: 'No trial on Nuance’s site',
    recognition: 'On your PC',
    offline: 'Yes, on Windows',
    privacy: 'Stays on your PC',
    everyApp: 'Windows apps, plus voice commands for the whole PC',
    meetings: 'Transcribes recordings',
    bestFor: 'Controlling a Windows PC by voice',
  },
  spokenly: {
    // spokenly.app; spokenly.app/pricing; spokenly.app/download (Mac, Windows, Linux, iPhone); spokenly.app/privacy;
    // spokenly.app/blog/wispr-flow-pricing (Pro monthly).
    id: 'spokenly',
    name: 'Spokenly',
    url: 'https://spokenly.app/',
    maker: 'Vadim Ahmerov',
    platforms: 'Mac, Windows, Linux, iPhone',
    price: 'Free for local use; Pro $9.99 a month or $99.99 a year',
    free: 'Free with on-device engines, no account',
    recognition: 'On your device, or in the cloud with Pro or your own key',
    offline: 'Yes, with on-device engines',
    privacy: 'On-device engines keep everything local; a local-only mode blocks every network request',
    everyApp: 'Every app',
    meetings: 'Records the mic and system audio on Mac',
    bestFor: 'Free local dictation on every desktop system',
  },
  monologue: {
    // www.monologue.to (plans, platforms, local transcription on Mac only, formatting needs a connection);
    // www.monologue.to/data-privacy.
    id: 'monologue',
    name: 'Monologue',
    url: 'https://www.monologue.to/',
    maker: 'Every',
    platforms: 'Mac, iPhone, iPad, Apple Watch',
    price: '$15 a month, or $144 a year',
    free: '1,000 words to try',
    recognition: 'In the cloud, with on-device transcription on Mac',
    offline: 'Raw transcription on Mac; formatting needs a connection',
    privacy: 'Dictation audio and text are not saved on its servers; saved notes sync through your account',
    everyApp: 'Every app',
    meetings: 'Meeting notes on Mac',
    bestFor: 'Formatted writing across Apple devices',
  },
};

