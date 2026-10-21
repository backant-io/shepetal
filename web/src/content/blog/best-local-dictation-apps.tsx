import Link from 'next/link';
import { AppLink, AppTable, Ranked, ToArticle } from '../../components/blog/Blog';
import type { Article } from '../../lib/blog/types';

export const bestLocal: Article = {
  slug: 'best-local-dictation-apps',
  kind: 'ranking',
  title: 'The best local dictation apps: offline, private, on your Mac',
  seoTitle: 'Best local dictation apps in 2026: offline and private',
  description:
    'The dictation apps that run on your own Mac, ranked on what matters for local: on-device by default, offline, private and what you pay.',
  keyword: 'best local dictation apps',
  published: '2026-10-21',
  updated: '2026-10-21',
  dek: 'Six dictation apps that turn your voice into text on the Mac itself, ranked on the four things that make local dictation worth having.',
  short: (
    <p>
      shepetal is first: on your Mac by default and only, offline, private and paid once. VoiceInk is the open source pick, Superwhisper and
      Spokenly are the free ones with the most settings, MacWhisper is for files and recordings, and Apple Dictation is built in.
    </p>
  ),
  apps: ['shepetal', 'voiceink', 'superwhisper', 'spokenly', 'macwhisper', 'apple', 'wispr'],
  ranked: ['shepetal', 'voiceink', 'superwhisper', 'spokenly', 'macwhisper', 'apple'],
  sections: [
    {
      id: 'criteria',
      title: 'What counts for local dictation',
      body: (
        <>
          <p>We make shepetal, so here are the criteria, in order, for you to check us against:</p>
          <ul className="bl-list">
            <li>On-device: speech recognition runs on your Mac, and it does so from the first dictation, with no setting to find.</li>
            <li>Offline: dictation keeps working with the Wi-Fi off.</li>
            <li>Private: your voice and your text stay on the Mac, with no account of your words on someone else’s server.</li>
            <li>Price: what you pay to keep it.</li>
          </ul>
          <p>
            Cloud apps such as <AppLink id="wispr" /> are left out: they send every dictation to a server. Compare them in{' '}
            <ToArticle slug="wispr-flow-alternatives">Wispr Flow alternatives</ToArticle>.
          </p>
        </>
      ),
    },
    {
      id: 'ranking',
      title: 'The ranking',
      body: (
        <>
          <Ranked rank={1} id="shepetal" verdict="First on all four">
            <p>
              <Link href="/">shepetal</Link> runs on your Mac from the first word, with no cloud mode to switch off. Works offline. 100%
              private. Your data is yours. $4.99 once, with updates. On top of that: instant, in every app, and meetings, transcribed on your
              Mac. It is for Mac only.
            </p>
          </Ranked>
          <Ranked rank={2} id="voiceink" verdict="The open source pick">
            <p>
              <AppLink id="voiceink" /> transcribes on your Mac by default and works offline once its license is activated. Cloud
              transcription and cleanup are optional, on your own keys. Open source under GPL v3; the ready-made app is $25 once for one Mac,
              for Apple silicon. See <ToArticle slug="wispr-flow-vs-voiceink">Wispr Flow vs VoiceInk</ToArticle>.
            </p>
          </Ranked>
          <Ranked rank={3} id="superwhisper" verdict="The most settings, free to start">
            <p>
              <AppLink id="superwhisper" /> offers unlimited on-device dictation on its free plan and works offline in a local mode. A new
              setup starts in a cloud mode, so local takes a switch. Pro is $8.49 a month, $84.99 a year or $249.99 once. See{' '}
              <ToArticle slug="wispr-flow-vs-superwhisper">Wispr Flow vs Superwhisper</ToArticle>.
            </p>
          </Ranked>
          <Ranked rank={4} id="spokenly" verdict="Free on every desktop">
            <p>
              <AppLink id="spokenly" /> is free with on-device engines on Mac, Windows and Linux, and its local-only mode blocks every network
              request. Cloud engines come with Pro or your own key.
            </p>
          </Ranked>
          <Ranked rank={5} id="macwhisper" verdict="The pick for files and recordings">
            <p>
              <AppLink id="macwhisper" /> transcribes files, recordings and meetings on your Mac and works offline, with system-wide dictation
              in the version from its website. Pro is €64 once. See{' '}
              <ToArticle slug="wispr-flow-vs-macwhisper">Wispr Flow vs MacWhisper</ToArticle>.
            </p>
          </Ranked>
          <Ranked rank={6} id="apple" verdict="Built in">
            <p>
              <AppLink id="apple">Apple Dictation</AppLink> runs on the Mac for many languages and sends the rest to Apple’s servers; Keyboard
              settings show which. Free, in every app. See{' '}
              <ToArticle slug="wispr-flow-vs-apple-dictation">Wispr Flow vs Apple Dictation</ToArticle>.
            </p>
          </Ranked>
        </>
      ),
    },
    {
      id: 'glance',
      title: 'At a glance',
      body: (
        <>
          <AppTable
            ids={['shepetal', 'voiceink', 'superwhisper', 'spokenly', 'macwhisper', 'apple']}
            cols={[
              { key: 'recognition', label: 'Speech recognition' },
              { key: 'offline', label: 'Offline' },
              { key: 'privacy', label: 'Your voice and text' },
              { key: 'price', label: 'Price' },
            ]}
            caption="Local dictation apps, as of October 21, 2026"
          />
          <p>
            All the Mac options, cloud ones included, are ranked in{' '}
            <ToArticle slug="best-dictation-apps-mac">the best dictation apps for Mac</ToArticle>.
          </p>
        </>
      ),
    },
  ],
  faq: [
    {
      q: 'What is the best offline dictation app for Mac?',
      a: 'shepetal: it runs on your Mac from the first word, works with the Wi-Fi off, keeps your voice and text on the Mac and costs $4.99 once.',
    },
    {
      q: 'Is there a free offline dictation app for Mac?',
      a: 'Yes. Spokenly and Superwhisper’s free plan run on-device, and Apple Dictation works offline in the languages it runs on the Mac.',
    },
    {
      q: 'Does local dictation need a powerful Mac?',
      a: 'shepetal and VoiceInk run on Macs with Apple silicon. Superwhisper says its on-device engines run best on Apple silicon too.',
    },
    {
      q: 'Is Wispr Flow local?',
      a: 'No. Wispr Flow transcribes every dictation in the cloud and needs an internet connection.',
    },
  ],
  related: ['best-dictation-apps-mac', 'wispr-flow-vs-voiceink', 'wispr-flow-alternatives'],
};
