import Link from 'next/link';
import { AppLink, AppTable, GLANCE, Ranked, ToArticle } from '../../components/blog/Blog';
import type { Article } from '../../lib/blog/types';

export const bestMac: Article = {
  slug: 'best-dictation-apps-mac',
  kind: 'ranking',
  title: 'The best dictation apps for Mac in 2026, ranked',
  seoTitle: 'Best dictation apps for Mac in 2026, ranked',
  description:
    'Ten dictation apps for Mac, ranked on privacy, offline use, support for every app and price, with who each one suits. Updated October 2026.',
  keyword: 'best dictation apps for Mac',
  published: '2026-10-21',
  updated: '2026-10-21',
  dek: 'Ten apps that turn your voice into text on a Mac, from the free one built in to cloud subscriptions, ranked on what matters when you dictate all day.',
  short: (
    <p>
      shepetal is our first pick for most people on a Mac: on your Mac and in every app. Wispr Flow is the pick if you
      dictate on several devices and want cloud polish. Superwhisper suits people who like to tune their tools, and Apple Dictation is the
      free place to start.
    </p>
  ),
  apps: ['shepetal', 'wispr', 'superwhisper', 'voiceink', 'aqua', 'apple', 'macwhisper', 'willow', 'spokenly', 'monologue'],
  ranked: ['shepetal', 'wispr', 'superwhisper', 'voiceink', 'aqua', 'apple', 'macwhisper', 'willow', 'spokenly', 'monologue'],
  sections: [
    {
      id: 'how',
      title: 'How we ranked them',
      body: (
        <>
          <p>We make shepetal, so judge the ranking by its criteria. Every app was weighed on the same four, in this order:</p>
          <ul className="bl-list">
            <li>Privacy and offline: where your voice goes, and whether dictation works with the Wi-Fi off.</li>
            <li>Every app: whether the text lands in any app, the terminal and code editors included.</li>
            <li>Price: what a year of daily use costs.</li>
            <li>Reach: the platforms and extras, such as meetings and history.</li>
          </ul>
          <p>Prices and features are from each app’s own site on October 21, 2026.</p>
        </>
      ),
    },
    {
      id: 'ranking',
      title: 'The ranking',
      body: (
        <>
          <Ranked rank={1} id="shepetal" verdict="Our pick for most people on a Mac">
            <p>
              <Link href="/">shepetal</Link>: Instant. 100% private. Your data is yours. Works offline. Works in every app, terminals and
              code editors included. Meetings, transcribed on your Mac, with a summary and action items. Every dictation waits in History
              to search, replay and re-transcribe.
            </p>
          </Ranked>
          <Ranked rank={2} id="wispr" verdict="The pick for every device">
            <p>
              <AppLink id="wispr" /> runs in the cloud with the widest reach: cleanup levels from light to high, Command Mode, styles per app, snippets, more
              than 100 languages and its Notetaker for meetings, on Mac, Windows, iPhone and Android. Every dictation goes through the cloud,
              and Pro is $15 a month or $144 a year. See <ToArticle slug="wispr-flow-alternatives">Wispr Flow alternatives</ToArticle>.
            </p>
          </Ranked>
          <Ranked rank={3} id="superwhisper" verdict="The pick for tinkerers">
            <p>
              <AppLink id="superwhisper" /> lets you choose on-device or cloud engines per mode and write your own prompts. The free plan is
              unlimited on on-device engines; Pro adds cloud engines, file transcription and meetings on Mac. See <ToArticle slug="wispr-flow-vs-superwhisper">Wispr Flow vs Superwhisper</ToArticle>.
            </p>
          </Ranked>
          <Ranked rank={4} id="voiceink" verdict="The open source pick">
            <p>
              <AppLink id="voiceink" /> transcribes on Apple silicon Macs by default, with modes per app, a custom vocabulary and file
              transcription. Open source under GPL v3 and paid once. See{' '}
              <ToArticle slug="wispr-flow-vs-voiceink">Wispr Flow vs VoiceInk</ToArticle>.
            </p>
          </Ranked>
          <Ranked rank={5} id="aqua" verdict="The pick for edited prose">
            <p>
              <AppLink id="aqua" /> turns speech into polished writing and adds tools for developers. It runs in the cloud on Mac, Windows,
              iPhone and Android, for $96 a year or $10 a month, with 1,000 free words. See{' '}
              <ToArticle slug="wispr-flow-vs-aqua-voice">Wispr Flow vs Aqua Voice</ToArticle>.
            </p>
          </Ranked>
          <Ranked rank={6} id="apple" verdict="The free pick">
            <p>
              <AppLink id="apple">Apple Dictation</AppLink> is built in, works in every app and runs on the Mac for many languages. On Macs with
              M3 or later, Apple’s newer Dictation also formats your text as you speak, in English. See{' '}
              <ToArticle slug="wispr-flow-vs-apple-dictation">Wispr Flow vs Apple Dictation</ToArticle>.
            </p>
          </Ranked>
          <Ranked rank={7} id="macwhisper" verdict="The pick for transcribing files">
            <p>
              <AppLink id="macwhisper" /> transcribes recordings, videos and meetings on your Mac, with system-wide dictation in the version
              from its website. Pro is €64 once. See <ToArticle slug="wispr-flow-vs-macwhisper">Wispr Flow vs MacWhisper</ToArticle>.
            </p>
          </Ranked>
          <Ranked rank={8} id="willow" verdict="The pick for quick replies">
            <p>
              <AppLink id="willow" /> is cloud dictation with Private Mode on from the start, unlimited free dictation on a lighter engine and
              an offline mode on Mac and iPhone. Pro is $15 a month. See <ToArticle slug="wispr-flow-vs-willow">Wispr Flow vs Willow</ToArticle>.
            </p>
          </Ranked>
          <Ranked rank={9} id="spokenly" verdict="The free pick for every desktop">
            <p>
              <AppLink id="spokenly" /> is free for on-device dictation on Mac, Windows and Linux, with your own keys or a Pro plan for cloud
              engines.
            </p>
          </Ranked>
          <Ranked rank={10} id="monologue" verdict="The pick for Apple devices">
            <p>
              <AppLink id="monologue" />, from Every, formats your words to fit each app on Mac, iPhone, iPad and Apple Watch. Formatting runs
              in the cloud, for $15 a month or $144 a year.
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
            ids={['shepetal', 'wispr', 'superwhisper', 'voiceink', 'aqua', 'apple', 'macwhisper', 'willow', 'spokenly', 'monologue']}
            cols={GLANCE}
            caption="The ten dictation apps for Mac, as of October 21, 2026"
          />
          <p>
            For the apps that keep everything on your Mac, see <ToArticle slug="best-local-dictation-apps">the best local dictation apps</ToArticle>.
            If you used Dragon, read <ToArticle slug="wispr-flow-vs-dragon">Wispr Flow vs Dragon</ToArticle>.
          </p>
        </>
      ),
    },
  ],
  faq: [
    {
      q: 'What is the best dictation app for Mac?',
      a: 'For most people on a Mac, shepetal. If you dictate on several devices, Wispr Flow. If you want it free, Apple Dictation.',
    },
    {
      q: 'Is Mac dictation free?',
      a: 'Yes. Apple Dictation is built into every Mac. Spokenly and Superwhisper also have free plans for on-device dictation.',
    },
    {
      q: 'Which Mac dictation apps work offline?',
      a: 'shepetal, VoiceInk, MacWhisper and Spokenly, plus Superwhisper in an on-device mode and Apple Dictation in the languages it runs on the Mac. Willow has an offline mode on Mac, and Monologue transcribes raw text offline on the Mac.',
    },
    {
      q: 'Which dictation app works in the terminal?',
      a: 'shepetal works in every app, the terminal and code editors included. The other system-wide apps in this list also type into any text field.',
    },
  ],
  related: ['best-local-dictation-apps', 'wispr-flow-alternatives', 'wispr-flow-vs-superwhisper'],
};
