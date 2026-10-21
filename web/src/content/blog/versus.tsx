import Link from 'next/link';
import { AppLink, Compare, Picks, ToArticle } from '../../components/blog/Blog';
import type { AppId, Article, Faq, Section } from '../../lib/blog/types';

/*
 * "Wispr Flow vs <X>": one article per alternative people search for next to Wispr Flow. Each puts shepetal in the
 * table too, and says plainly who should pick which. Facts are from src/lib/blog/apps.ts and the sources listed there.
 */

type Vs = {
  other: AppId;
  slug: string;
  kind: 'comparison';
  title: string;
  seoTitle: string;
  description: string;
  keyword: string;
  dek: string;
  short: React.ReactNode;
  sections: Section[];
  faq: Faq[];
  related: string[];
};

const DATE = '2026-10-21';

function vs(o: Vs): Article {
  return { ...o, published: DATE, updated: DATE, apps: ['wispr', o.other, 'shepetal'] };
}

const table = (other: AppId, name: string): Section => ({
  id: 'side-by-side',
  title: 'Side by side',
  body: <Compare ids={['wispr', other, 'shepetal']} caption={`Wispr Flow, ${name} and shepetal, as of October 21, 2026`} />,
});

export const VERSUS: Article[] = [
  vs({
    other: 'superwhisper',
    slug: 'wispr-flow-vs-superwhisper',
    kind: 'comparison',
    title: 'Wispr Flow vs Superwhisper: cloud polish or local control',
    seoTitle: 'Wispr Flow vs Superwhisper (2026): price, privacy, offline',
    description:
      'Wispr Flow vs Superwhisper on price, platforms, offline use and where your voice goes, with shepetal, the dictation app that stays on your Mac.',
    keyword: 'Wispr Flow vs Superwhisper',
    dek: 'Both put your words into any app. Wispr Flow does it in the cloud on every device. Superwhisper lets you pick the engine, on your device or in the cloud.',
    short: (
      <p>
        Pick Wispr Flow for polished text on every device, with nothing to set up. Pick Superwhisper to choose the engine, the prompt and
        where the work happens. For dictation that stays on your Mac with nothing to choose, pick shepetal.
      </p>
    ),
    sections: [
      table('superwhisper', 'Superwhisper'),
      {
        id: 'privacy',
        title: 'Where your voice goes',
        body: (
          <>
            <p>
              <AppLink id="wispr" /> transcribes every dictation in the cloud. Its privacy page says the audio is deleted once it is
              transcribed, unless you turn on cloud storage for your history. Its help center says the setting that shares your dictations
              to improve Wispr’s speech recognition starts on for the Free and Pro plans. You can turn it off, and the Growth and Enterprise
              plans keep it off.
            </p>
            <p>
              <AppLink id="superwhisper" /> works one mode at a time, on your device or in the cloud. The free plan uses on-device engines
              only. A new setup starts with a cloud mode, so pick a local mode if you want every word on the Mac. Cloud modes go to
              providers on zero-retention terms, and your history stays on your device.
            </p>
            <p>
              <Link href="/">shepetal</Link> has one way to work: on your Mac. 100% private. Your data is yours. There is no mode to pick and
              no setting to check.
            </p>
          </>
        ),
      },
      {
        id: 'price',
        title: 'What you pay',
        body: (
          <>
            <p>
              Wispr Flow Pro is $15 a month or $144 a year, and the free plan gives you 2,000 words a week on Mac and Windows. Superwhisper
              Pro is $8.49 a month, $84.99 a year or $249.99 once, and its free plan has unlimited on-device dictation. One Superwhisper
              license covers your Macs, PCs and phones.
            </p>
            <p>shepetal is $4.99 once, with updates.</p>
          </>
        ),
      },
      {
        id: 'strengths',
        title: 'What each one does best',
        body: (
          <>
            <h3>Wispr Flow</h3>
            <p>
              Cleanup in four levels, Command Mode to rewrite selected text by voice, styles per app, a dictionary and snippets, more than 100
              languages and apps for iPhone and Android. Its Notetaker records meetings on Mac and Windows.
            </p>
            <h3>Superwhisper</h3>
            <p>
              Modes with your own prompts, a choice of on-device and cloud engines, transcription of audio and video files, meetings on Mac
              and more than 100 languages. Made for people who like to tune their tools.
            </p>
            <h3>shepetal</h3>
            <p>
              Instant. One key works in every app, terminals and code editors included. Meetings, transcribed on your Mac. Every dictation
              waits in History to search, replay and re-transcribe.
            </p>
          </>
        ),
      },
      {
        id: 'pick',
        title: 'Which one to pick',
        body: (
          <>
            <Picks
              picks={[
                { id: 'wispr', why: 'you dictate on several devices and want the text cleaned up for you, and the cloud is fine with you.' },
                { id: 'superwhisper', why: 'you want to choose engines and write your own prompts, and you dictate on Windows or Android too.' },
                { id: 'shepetal', why: 'you work on a Mac and want every word on it, with nothing to configure.' },
              ]}
            />
            <p>
              More options are in <ToArticle slug="wispr-flow-alternatives">Wispr Flow alternatives</ToArticle>, and the apps that run
              entirely on your Mac are ranked in <ToArticle slug="best-local-dictation-apps">the best local dictation apps</ToArticle>.
            </p>
          </>
        ),
      },
    ],
    faq: [
      {
        q: 'Is Superwhisper free?',
        a: 'Superwhisper has a free plan with unlimited dictation on on-device engines. Pro costs $8.49 a month, $84.99 a year or $249.99 once, and new users get 3,000 words of Pro to try.',
      },
      { q: 'Does Wispr Flow work offline?', a: 'No. Wispr Flow transcribes in the cloud, so every dictation needs an internet connection.' },
      {
        q: 'Which keeps my voice more private, Wispr Flow or Superwhisper?',
        a: 'Superwhisper in an on-device mode keeps your audio on your device. Wispr Flow sends every dictation to its servers. shepetal keeps your voice and your text on your Mac, with no mode to pick.',
      },
      {
        q: 'Do Wispr Flow and Superwhisper run on Windows?',
        a: 'Yes. Both run on Mac, Windows, iPhone and Android. shepetal is for Mac.',
      },
    ],
    related: ['wispr-flow-vs-voiceink', 'best-local-dictation-apps', 'wispr-flow-alternatives'],
  }),

  vs({
    other: 'macwhisper',
    slug: 'wispr-flow-vs-macwhisper',
    kind: 'comparison',
    title: 'Wispr Flow vs MacWhisper: live dictation or transcription on your Mac',
    seoTitle: 'Wispr Flow vs MacWhisper (2026): price, privacy, offline',
    description:
      'Wispr Flow is cloud dictation on every device. MacWhisper transcribes files and meetings on your Mac. How they compare, and where shepetal fits.',
    keyword: 'Wispr Flow vs MacWhisper',
    dek: 'Wispr Flow is dictation in the cloud, on every device. MacWhisper is a transcription app for your Mac that also dictates. They do different jobs.',
    short: (
      <p>
        Pick Wispr Flow if you dictate all day on several devices and want the text polished for you. Pick MacWhisper if most of your audio
        is recordings, files and meetings you want transcribed on your Mac. For live dictation that stays on your Mac, pick shepetal.
      </p>
    ),
    sections: [
      table('macwhisper', 'MacWhisper'),
      {
        id: 'jobs',
        title: 'Two different jobs',
        body: (
          <>
            <p>
              <AppLink id="wispr" /> is made for one moment: you speak, and polished text lands where your cursor is. It does that on Mac,
              Windows, iPhone and Android, with cleanup, a dictionary, snippets and Command Mode to rewrite text by voice.
            </p>
            <p>
              <AppLink id="macwhisper" /> is made for audio. Drop in an MP3, a video or a recording and it transcribes it on your Mac.
              Pro adds batch transcription, speaker recognition, translation, watched folders and automatic recording of calls in Zoom, Teams
              and more. System-wide dictation is in the free version too. Buy it from its website: the Mac App Store edition is a separate
              app without system-wide dictation.
            </p>
          </>
        ),
      },
      {
        id: 'privacy',
        title: 'Where your voice goes',
        body: (
          <>
            <p>
              Wispr Flow sends every dictation to its servers. The audio is deleted after transcription unless you turn on cloud storage, and
              meeting notes from its Notetaker are stored in Wispr’s cloud.
            </p>
            <p>
              MacWhisper transcribes on your Mac by default and works with the Wi-Fi off. Its cloud services are optional and run on API keys
              you bring yourself.
            </p>
            <p>
              <Link href="/">shepetal</Link> keeps dictation and meetings on your Mac. 100% private. Your data is yours.
            </p>
          </>
        ),
      },
      {
        id: 'price',
        title: 'What you pay',
        body: (
          <p>
            Wispr Flow Pro is $15 a month or $144 a year. MacWhisper has a free version, and Pro is €64 once with lifetime updates. shepetal
            is $4.99 once, with updates.
          </p>
        ),
      },
      {
        id: 'pick',
        title: 'Which one to pick',
        body: (
          <>
            <Picks
              picks={[
                { id: 'wispr', why: 'you dictate more than you record, on more than one device, and want the text edited for you.' },
                { id: 'macwhisper', why: 'you transcribe interviews, lectures, videos or calls, and want it done on your Mac.' },
                {
                  id: 'shepetal',
                  why: 'you want live dictation in every app and meetings, transcribed on your Mac. Instant, with one key.',
                },
              ]}
            />
            <p>
              See how the rest compare in <ToArticle slug="best-dictation-apps-mac">the best dictation apps for Mac</ToArticle>, or read{' '}
              <ToArticle slug="wispr-flow-vs-superwhisper">Wispr Flow vs Superwhisper</ToArticle>.
            </p>
          </>
        ),
      },
    ],
    faq: [
      {
        q: 'Is MacWhisper a one-time purchase?',
        a: 'Yes. MacWhisper Pro is €64 once with lifetime updates, from its website. There is also a free version. The App Store edition is a separate app with subscriptions.',
      },
      {
        q: 'Does MacWhisper work offline?',
        a: 'Yes. It transcribes on your Mac with local engines. Cloud services are optional and use your own API keys.',
      },
      {
        q: 'Can Wispr Flow transcribe audio files?',
        a: 'Wispr Flow’s site lists live dictation and meeting notes. For audio and video files, MacWhisper is the one built for it.',
      },
      {
        q: 'Which one works in every app?',
        a: 'Both dictate into any app on the Mac: Wispr Flow everywhere, MacWhisper in the version from its website. shepetal works in every app too, terminals and code editors included.',
      },
    ],
    related: ['best-dictation-apps-mac', 'wispr-flow-vs-superwhisper', 'best-local-dictation-apps'],
  }),

  vs({
    other: 'aqua',
    slug: 'wispr-flow-vs-aqua-voice',
    kind: 'comparison',
    title: 'Wispr Flow vs Aqua Voice: two cloud dictation apps, compared',
    seoTitle: 'Wispr Flow vs Aqua Voice (2026): price, privacy, offline',
    description:
      'Wispr Flow vs Aqua Voice: plans, free words, languages, privacy modes and offline use, side by side, with shepetal for dictation on your Mac.',
    keyword: 'Wispr Flow vs Aqua Voice',
    dek: 'Two cloud dictation apps for Mac, Windows, iPhone and Android. Here is what sets them apart, and what to pick if you want your voice on your Mac.',
    short: (
      <p>
        Both run in the cloud on Mac, Windows, iPhone and Android. Aqua Voice costs less per year and puts edited prose and developer tools
        first. Wispr Flow has a weekly free allowance, more languages and meeting notes. For dictation that runs on your Mac, pick shepetal.
      </p>
    ),
    sections: [
      table('aqua', 'Aqua Voice'),
      {
        id: 'differences',
        title: 'Where they differ',
        body: (
          <>
            <p>
              <AppLink id="aqua" /> cleans up every dictation into edited text, rewrites a selection with Edit Mode and shows your words as you
              speak in its Max plan. It speaks 49 languages and ships tools for developers: an API, a command line and file tagging in code
              editors.
            </p>
            <p>
              <AppLink id="wispr" /> offers cleanup in four levels, Command Mode, styles per app, snippets and more than 100 languages. Its
              Notetaker records meetings on Mac and Windows. Aqua Voice has no meeting recorder.
            </p>
          </>
        ),
      },
      {
        id: 'privacy',
        title: 'Where your voice goes',
        body: (
          <>
            <p>
              Both send your audio to their servers. Aqua Voice says that with Privacy Mode on, nothing is stored there, and its Business plan
              adds zero data retention. Wispr Flow deletes the audio after transcription unless you turn on cloud storage, and has a setting
              that shares dictations to improve its speech recognition.
            </p>
            <p>
              Aqua Voice says it has no offline mode on the desktop, and Wispr Flow needs a connection for every dictation.{' '}
              <Link href="/">shepetal</Link> runs on your Mac. Works offline.
            </p>
          </>
        ),
      },
      {
        id: 'price',
        title: 'What you pay',
        body: (
          <p>
            Aqua Voice Pro is $10 a month, or $96 a year billed yearly. Max is $30 a month, or $288 a year. Wispr Flow Pro is $15 a month or
            $144 a year. Aqua Voice gives you 1,000 words to try; Wispr Flow gives 2,000 words every week on Mac and Windows. shepetal is $4.99
            once, with updates.
          </p>
        ),
      },
      {
        id: 'pick',
        title: 'Which one to pick',
        body: (
          <>
            <Picks
              picks={[
                { id: 'wispr', why: 'you want a free weekly allowance, meeting notes and the widest choice of languages.' },
                { id: 'aqua', why: 'you want edited prose, a lower yearly price and tools for coding work.' },
                { id: 'shepetal', why: 'you want your voice to stay on your Mac. 100% private. Your data is yours.' },
              ]}
            />
            <p>
              Comparing more cloud apps? Read <ToArticle slug="wispr-flow-vs-willow">Wispr Flow vs Willow</ToArticle> and the full list of{' '}
              <ToArticle slug="wispr-flow-alternatives">Wispr Flow alternatives</ToArticle>.
            </p>
          </>
        ),
      },
    ],
    faq: [
      {
        q: 'Is Aqua Voice cheaper than Wispr Flow?',
        a: 'Per year, yes. Aqua Voice Pro is $96 a year or $10 a month. Wispr Flow Pro is $144 a year or $15 a month.',
      },
      { q: 'Does Aqua Voice work offline?', a: 'No, on Mac and Windows. Aqua Voice transcribes in the cloud and says it has no offline mode there.' },
      {
        q: 'Does Aqua Voice have a free plan?',
        a: 'Aqua Voice gives new users 1,000 free words. Wispr Flow’s free plan gives 2,000 words a week on Mac and Windows.',
      },
      { q: 'Which one records meetings?', a: 'Wispr Flow, with its Notetaker on Mac and Windows. shepetal transcribes meetings on your Mac.' },
    ],
    related: ['wispr-flow-vs-willow', 'wispr-flow-alternatives', 'best-dictation-apps-mac'],
  }),

  vs({
    other: 'willow',
    slug: 'wispr-flow-vs-willow',
    kind: 'comparison',
    title: 'Wispr Flow vs Willow: the same price, different defaults',
    seoTitle: 'Wispr Flow vs Willow Voice (2026): price, privacy, offline',
    description:
      'Wispr Flow vs Willow Voice: plans, free tiers, privacy defaults, offline mode and platforms, side by side, with shepetal for dictation on your Mac.',
    keyword: 'Wispr Flow vs Willow',
    dek: 'Wispr Flow and Willow charge the same for Pro and both run in the cloud. Their defaults are where they part.',
    short: (
      <p>
        Willow keeps Private Mode on from the start and has an offline mode on Mac and iPhone. Wispr Flow runs on Android as well and records
        meetings. For dictation that runs on your Mac every time, pick shepetal.
      </p>
    ),
    sections: [
      table('willow', 'Willow'),
      {
        id: 'privacy',
        title: 'Defaults and privacy',
        body: (
          <>
            <p>
              <AppLink id="willow" /> runs in the cloud with Private Mode on from the start: Willow’s privacy policy says audio and dictated
              text are not kept, and sharing text to improve Willow is opt-in. An offline mode on Mac and iPhone runs on your device.
            </p>
            <p>
              <AppLink id="wispr" /> runs in the cloud on every dictation. Audio is deleted after transcription unless you turn on cloud
              storage. Its help center says the setting that shares your dictations to improve Wispr’s speech recognition starts on for Free
              and Pro, and you can turn it off.
            </p>
            <p>
              <Link href="/">shepetal</Link> has no cloud path to switch off. 100% private. Your data is yours.
            </p>
          </>
        ),
      },
      {
        id: 'features',
        title: 'Features',
        body: (
          <>
            <p>
              Willow Scribe drafts polished text from what you mean to say, 20 times a week on the free plan and without limit on Pro. Willow
              learns your writing style, keeps an auto-learning dictionary and speaks more than 100 languages.
            </p>
            <p>
              Wispr Flow has cleanup levels, Command Mode, snippets, styles per app, more than 100 languages, an Android app and its Notetaker
              for meetings.
            </p>
            <p>shepetal: Instant. 4x faster than typing. Meetings, transcribed on your Mac.</p>
          </>
        ),
      },
      {
        id: 'price',
        title: 'What you pay',
        body: (
          <p>
            Pro is $15 a month at both, or $12 a month billed yearly. Willow’s free plan has unlimited dictation on a lighter speech engine;
            Wispr Flow’s free plan has 2,000 words a week on Mac and Windows. shepetal is $4.99 once, with updates.
          </p>
        ),
      },
      {
        id: 'pick',
        title: 'Which one to pick',
        body: (
          <>
            <Picks
              picks={[
                { id: 'wispr', why: 'you use Android or want meeting notes alongside dictation.' },
                { id: 'willow', why: 'you want unlimited free dictation and private defaults, and you write a lot of quick replies.' },
                { id: 'shepetal', why: 'you work on a Mac and want dictation that runs on it every time.' },
              ]}
            />
            <p>
              Read <ToArticle slug="wispr-flow-vs-aqua-voice">Wispr Flow vs Aqua Voice</ToArticle> for another cloud comparison, or{' '}
              <ToArticle slug="best-local-dictation-apps">the best local dictation apps</ToArticle> for the ones that stay on your Mac.
            </p>
          </>
        ),
      },
    ],
    faq: [
      {
        q: 'Is Willow Voice free?',
        a: 'Willow has a free plan with unlimited dictation on a lighter speech engine and 20 Scribe uses a week. Pro is $15 a month, or $12 a month billed yearly.',
      },
      {
        q: 'Does Willow work offline?',
        a: 'Willow has an offline mode on Mac and iPhone that runs on your device. On Windows it works in the cloud.',
      },
      { q: 'Does Willow run on Android?', a: 'Willow lists Android as coming soon. Wispr Flow has an Android app.' },
      { q: 'Is shepetal on Windows or Android?', a: 'shepetal is for Mac.' },
    ],
    related: ['wispr-flow-vs-aqua-voice', 'best-local-dictation-apps', 'wispr-flow-alternatives'],
  }),

  vs({
    other: 'voiceink',
    slug: 'wispr-flow-vs-voiceink',
    kind: 'comparison',
    title: 'Wispr Flow vs VoiceInk: a cloud subscription or local, paid once',
    seoTitle: 'Wispr Flow vs VoiceInk (2026): price, privacy, offline',
    description:
      'Wispr Flow vs VoiceInk: a cloud subscription against open source dictation paid once. Price, privacy and offline use, with shepetal next to them.',
    keyword: 'Wispr Flow vs VoiceInk',
    dek: 'Wispr Flow is a cloud subscription on every device. VoiceInk is open source dictation for Apple silicon Macs, paid once.',
    short: (
      <p>
        Pick Wispr Flow for polished text on every device with nothing to configure. Pick VoiceInk for local dictation on an Apple silicon
        Mac with open source code and many settings. shepetal is local and paid once as well, with meetings transcribed on your Mac.
      </p>
    ),
    sections: [
      table('voiceink', 'VoiceInk'),
      {
        id: 'privacy',
        title: 'Where your voice goes',
        body: (
          <>
            <p>
              <AppLink id="voiceink" /> transcribes on your Mac by default, and its privacy policy says it stores no transcripts or audio on
              its servers. Cloud transcription and cloud cleanup are optional and use API keys you bring; a cloud cleanup provider receives
              your text. The local engines work offline once the license is activated.
            </p>
            <p>
              <AppLink id="wispr" /> sends every dictation to its servers and needs a connection each time.
            </p>
            <p>
              <Link href="/">shepetal</Link> runs on your Mac, with no cloud provider to connect. 100% private. Your data is yours.
            </p>
          </>
        ),
      },
      {
        id: 'features',
        title: 'Features',
        body: (
          <>
            <p>
              VoiceInk has a custom vocabulary, word replacements, modes per app and per website, context from your screen, file
              transcription and a choice of local engines. Its source code is on GitHub under GPL v3, and you can build it yourself.
            </p>
            <p>
              Wispr Flow has cleanup levels, Command Mode, snippets, more than 100 languages, apps for iPhone and Android and its Notetaker for
              meetings on Mac and Windows.
            </p>
            <p>
              shepetal is instant, works in every app with one key, and transcribes meetings on your Mac with a summary and action items.
            </p>
          </>
        ),
      },
      {
        id: 'price',
        title: 'What you pay',
        body: (
          <p>
            VoiceInk is $25 once for one Mac, $39 for two and $49 for three, with lifetime updates and a 7-day trial. Wispr Flow Pro is $15 a
            month or $144 a year. shepetal is $4.99 once, with updates.
          </p>
        ),
      },
      {
        id: 'pick',
        title: 'Which one to pick',
        body: (
          <>
            <Picks
              picks={[
                { id: 'wispr', why: 'you dictate on Windows, iPhone or Android as well as your Mac and want the text cleaned up for you.' },
                { id: 'voiceink', why: 'you want local dictation with every setting exposed, and open source code you can build.' },
                { id: 'shepetal', why: 'you want local dictation with one key and meetings on your Mac, with nothing to configure.' },
              ]}
            />
            <p>
              Both local apps are in <ToArticle slug="best-local-dictation-apps">the best local dictation apps</ToArticle>. For another local
              option, read <ToArticle slug="wispr-flow-vs-superwhisper">Wispr Flow vs Superwhisper</ToArticle>.
            </p>
          </>
        ),
      },
    ],
    faq: [
      {
        q: 'Is VoiceInk free?',
        a: 'VoiceInk is open source under GPL v3, so you can build it yourself at no cost. The ready-made app is $25 once for one Mac, $39 for two or $49 for three, with a 7-day trial.',
      },
      { q: 'Does VoiceInk work offline?', a: 'Yes, with its local engines. It needs a connection once to activate the license.' },
      {
        q: 'Does VoiceInk run on Intel Macs?',
        a: 'VoiceInk’s pricing page lists Apple silicon and macOS 14.4 or later. Wispr Flow has a separate download for Intel Macs.',
      },
      { q: 'Is shepetal open source?', a: 'Yes. shepetal’s source code is public under the MIT license.' },
    ],
    related: ['best-local-dictation-apps', 'wispr-flow-vs-superwhisper', 'wispr-flow-alternatives'],
  }),

  vs({
    other: 'apple',
    slug: 'wispr-flow-vs-apple-dictation',
    kind: 'comparison',
    title: 'Wispr Flow vs Apple Dictation: the free one, or the polished one',
    seoTitle: 'Wispr Flow vs Apple Dictation (2026): cost, privacy, offline',
    description:
      'Apple Dictation is free and built into your Mac. Wispr Flow adds cleanup and every device, in the cloud. How they compare, and where shepetal fits.',
    keyword: 'Wispr Flow vs Apple Dictation',
    dek: 'Apple Dictation comes with your Mac and works in every app. Wispr Flow is a subscription that rewrites what you say. Here is the difference.',
    short: (
      <p>
        Apple Dictation is free, built in and works in every app, on the Mac itself for many languages. Wispr Flow adds cleanup, a dictionary,
        snippets and every device, in the cloud, for a subscription. shepetal runs on your Mac with cleanup, history and meetings, paid once.
      </p>
    ),
    sections: [
      table('apple', 'Apple Dictation'),
      {
        id: 'apple',
        title: 'What Apple Dictation does',
        body: (
          <>
            <p>
              <AppLink id="apple">Apple Dictation</AppLink> is in every Mac. Turn it on in Keyboard settings, pick a shortcut such as pressing
              fn twice, and speak into any text field. Apple’s guide says you can dictate text of any length without a timeout; it stops when
              it hears no speech for 30 seconds. In supported languages it adds commas, periods and question marks for you.
            </p>
            <p>
              Keyboard settings show whether your language runs on the Mac or on Apple’s servers. On the Mac, it works with the Wi-Fi off.
              On the servers, your audio goes to Apple. Improve Siri & Dictation, which lets Apple store and review recordings, is opt-in,
              and Apple’s privacy page says it can keep transcripts of server dictation for as long as two years under a rotating random
              identifier.
            </p>
            <p>Apple Dictation keeps no history and has no custom dictionary or meeting transcription. Voice Control, in Accessibility settings, adds a custom vocabulary and voice commands.</p>
          </>
        ),
      },
      {
        id: 'wispr',
        title: 'What Wispr Flow adds',
        body: (
          <p>
            <AppLink id="wispr" /> rewrites what you say into clean text, with four cleanup levels, styles per app, a dictionary that learns,
            snippets and Command Mode to edit a selection by voice. It keeps a history, records meetings with its Notetaker and runs on Mac,
            Windows, iPhone and Android. All of it runs in the cloud, for $15 a month or $144 a year, with 2,000 free words a week on Mac and
            Windows.
          </p>
        ),
      },
      {
        id: 'shepetal',
        title: 'Where shepetal fits',
        body: (
          <p>
            <Link href="/">shepetal</Link> runs on your Mac in every language it offers, and it is instant. It removes filler words, keeps
            every dictation in History to search, replay and re-transcribe, reads your own dictionary and transcribes meetings on your Mac.
            One key, in every app. $4.99 once, with updates.
          </p>
        ),
      },
      {
        id: 'pick',
        title: 'Which one to pick',
        body: (
          <>
            <Picks
              picks={[
                { id: 'apple', why: 'you dictate short notes and messages, and free and built in matters most.' },
                { id: 'wispr', why: 'you want every word rewritten into clean text on every device, and a subscription is fine.' },
                { id: 'shepetal', why: 'you want more than the built-in dictation with your voice still on your Mac. 100% private.' },
              ]}
            />
            <p>
              Every option for the Mac is ranked in <ToArticle slug="best-dictation-apps-mac">the best dictation apps for Mac</ToArticle>, and
              the private ones in <ToArticle slug="best-local-dictation-apps">the best local dictation apps</ToArticle>.
            </p>
          </>
        ),
      },
    ],
    faq: [
      {
        q: 'Does Apple Dictation have a time limit on the Mac?',
        a: 'Apple’s Mac User Guide says you can dictate text of any length without a timeout. Dictation stops when it hears no speech for 30 seconds.',
      },
      {
        q: 'Does Apple Dictation work offline?',
        a: 'Yes, in the languages it runs on your Mac. Keyboard settings show whether your language runs on the Mac or on Apple’s servers.',
      },
      {
        q: 'Is Apple Dictation private?',
        a: 'In the languages that run on the Mac, your voice stays on it. Server dictation goes to Apple. Improve Siri & Dictation, which stores recordings, is opt-in.',
      },
      {
        q: 'Is Wispr Flow worth it over the free Apple Dictation?',
        a: 'If you want cleanup, a dictionary, snippets and every device, and the cloud is fine with you, Wispr Flow adds those. If you want those extras on your Mac and paid once, shepetal has them.',
      },
    ],
    related: ['best-dictation-apps-mac', 'best-local-dictation-apps', 'wispr-flow-alternatives'],
  }),

  vs({
    other: 'dragon',
    slug: 'wispr-flow-vs-dragon',
    kind: 'comparison',
    title: 'Wispr Flow vs Dragon: dictation on a Mac after Dragon',
    seoTitle: 'Wispr Flow vs Dragon (2026): dictation for Mac users',
    description:
      'Dragon left the Mac in 2018. How Wispr Flow compares with Dragon Professional on Windows, and what Mac users who liked Dragon pick today.',
    keyword: 'Wispr Flow vs Dragon',
    dek: 'Dragon has had no Mac version since 2018. Here is how Wispr Flow compares with Dragon on Windows, and what a Mac user picks today.',
    short: (
      <p>
        On a Mac, Dragon is no longer an option: Nuance ended Dragon for Mac in 2018 and sells Dragon Professional for Windows only. Wispr
        Flow is a cloud option on Mac and Windows. If you liked Dragon because it ran on your own computer, shepetal runs on your Mac.
      </p>
    ),
    sections: [
      table('dragon', 'Dragon'),
      {
        id: 'dragon',
        title: 'Where Dragon stands in 2026',
        body: (
          <>
            <p>
              Nuance, now part of Microsoft, discontinued Dragon Professional Individual for Mac on October 22, 2018. Its{' '}
              <AppLink id="dragon">Dragon products</AppLink> today run on Windows: Dragon Professional v16 installs on your PC, needs the
              internet only to download and activate, and dictates offline. It controls the whole PC by voice, learns your voice, takes custom
              words and transcribes recordings. Nuance lists no public price; you buy through its sales team or a reseller.
            </p>
            <p>Dragon Anywhere, the mobile app, stopped taking new subscriptions and renewals on July 1, 2026, according to its App Store listing.</p>
          </>
        ),
      },
      {
        id: 'wispr',
        title: 'Wispr Flow for former Dragon users',
        body: (
          <p>
            <AppLink id="wispr" /> runs on Mac, Windows, iPhone and Android, works in any app and rewrites what you say into clean text. It
            runs in the cloud, so it needs a connection for every dictation, and it costs $15 a month or $144 a year. It has no voice
            commands for controlling your computer the way Dragon does.
          </p>
        ),
      },
      {
        id: 'shepetal',
        title: 'shepetal for former Dragon users',
        body: (
          <p>
            Like Dragon on Windows, <Link href="/">shepetal</Link> runs on your own computer. Works offline. 100% private. Your data is yours.
            Press the key and speak in any app, keep a dictionary of your own words, and find every dictation again in History. Meetings,
            transcribed on your Mac.
          </p>
        ),
      },
      {
        id: 'pick',
        title: 'Which one to pick',
        body: (
          <>
            <Picks
              picks={[
                { id: 'dragon', why: 'you work on Windows and control the whole PC by voice.' },
                { id: 'wispr', why: 'you move between a Mac, a PC and your phone, and the cloud is fine with you.' },
                { id: 'shepetal', why: 'you work on a Mac and want dictation that runs on it, the way Dragon ran on your PC.' },
              ]}
            />
            <p>
              For voice control on a Mac, Apple’s built-in Voice Control is the closest match; see{' '}
              <ToArticle slug="wispr-flow-vs-apple-dictation">Wispr Flow vs Apple Dictation</ToArticle>. Every Mac option is ranked in{' '}
              <ToArticle slug="best-dictation-apps-mac">the best dictation apps for Mac</ToArticle>.
            </p>
          </>
        ),
      },
    ],
    faq: [
      {
        q: 'Is there a Dragon for Mac in 2026?',
        a: 'No. Nuance discontinued Dragon Professional Individual for Mac on October 22, 2018, and its current Dragon products run on Windows.',
      },
      {
        q: 'Does Dragon work offline?',
        a: 'Dragon Professional on Windows runs on your PC and needs the internet only to download and activate it.',
      },
      {
        q: 'Is Dragon Anywhere still available?',
        a: 'Its App Store listing says Dragon Anywhere stopped selling new subscriptions and renewals on July 1, 2026.',
      },
      {
        q: 'What is the closest thing to Dragon on a Mac?',
        a: 'For dictation that runs on your own computer, shepetal. For controlling the Mac by voice, Apple’s built-in Voice Control.',
      },
    ],
    related: ['best-dictation-apps-mac', 'wispr-flow-vs-apple-dictation', 'wispr-flow-alternatives'],
  }),
];
