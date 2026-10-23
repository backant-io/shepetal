import type { Metadata } from 'next';
import { pageMetadata } from '@/lib/seo';
import Link from 'next/link';
import { InstallSteps } from '@/components/site/InstallSteps';
import { SiteHeader } from '@/components/site/Shell';
import { SITE_URL } from '@/lib/site';
import { waitlistOn } from '@/lib/waitlist-config';

export const metadata: Metadata = pageMetadata('faq', { title: 'FAQ', description: 'Installing shepetal, privacy, offline use, languages, the Macs it runs on, prices, refunds and what comes next.' });

type QA = { q: string; a: React.ReactNode; text: string };

/** Each answer twice: as the page shows it, and as plain text for the FAQPage structured data. */
const QAS: QA[] = [
  {
    q: 'What is shepetal?',
    a: <p>Dictation for Mac. Press one key, and your words appear wherever your cursor is: mail, chat, code, notes, any app.</p>,
    text: 'Dictation for Mac. Press one key, and your words appear wherever your cursor is: mail, chat, code, notes, any app.',
  },
  {
    q: 'Does my voice leave my Mac?',
    a: (
      <>
        <p>
          No. Your voice never leaves your Mac. Speech recognition runs on your Mac, and your recordings and history
          stay there, in your user folder.
        </p>
        <p>
          Your words go where you put them: into the app you dictate into. shepetal itself sends no text and no
          analytics. To sign in it uses your Google email, and it checks your license once a day. The details are in
          the <Link href="/privacy">Privacy Policy</Link>.
        </p>
      </>
    ),
    text: 'No. Your voice never leaves your Mac. Speech recognition runs on your Mac, and your recordings and history stay there. Your words go where you put them: into the app you dictate into. shepetal itself sends no text and no analytics. To sign in it uses your Google email, and it checks your license once a day.',
  },
  {
    q: 'Does it work offline?',
    a: (
      <p>
        Speech recognition needs no internet. You are online once to set up: you sign in, and you download speech
        recognition (about 470 MB) from the 🤫 menu. After that you can dictate on a plane. A lifetime license works
        offline with no limit; during the trial, shepetal checks your license at least once every 7 days.
      </p>
    ),
    text: 'Speech recognition needs no internet. You are online once to set up: you sign in, and you download speech recognition (about 470 MB). After that you can dictate on a plane. A lifetime license works offline with no limit; during the trial, shepetal checks your license at least once every 7 days.',
  },
  {
    q: 'Which languages does it understand?',
    a: (
      <p>
        25 European languages, among them English, German, French, Spanish, Italian, Portuguese, Dutch, Polish,
        Ukrainian and Slovene. Automatic picks the one you speak, or choose yours under Languages in the 🤫 menu.
      </p>
    ),
    text: '25 European languages, among them English, German, French, Spanish, Italian, Portuguese, Dutch, Polish, Ukrainian and Slovene. Automatic picks the one you speak, or choose yours under Languages in the menu.',
  },
  {
    q: 'Which Macs does it run on?',
    a: <p>Macs with Apple silicon (M1 or later) and macOS 14.4 or later. Intel Macs are not supported.</p>,
    text: 'Macs with Apple silicon (M1 or later) and macOS 14.4 or later. Intel Macs are not supported.',
  },
  {
    q: 'How do I install it?',
    a: (
      <>
        <p>
          shepetal is not notarized by Apple, so macOS asks you to allow it once. <a href="/download">Download</a> it,
          then:
        </p>
        <InstallSteps headingLevel={3} />
      </>
    ),
    text: 'Download shepetal. Open the DMG and drag shepetal into Applications. Open it; when macOS says it cannot open or could not verify shepetal, close the message (on macOS 15, click Done). Then open System Settings, Privacy & Security, scroll to the message that shepetal was blocked, click Open Anyway (it is there for about an hour after you tried to open it) and confirm with your password. On macOS 14 you can instead Control-click shepetal in Applications, choose Open, then Open. You do this once.',
  },
  {
    q: 'How do I uninstall it?',
    a: (
      <p>
        Quit shepetal from the 🤫 menu and drag it from Applications to the Trash. Your recordings and history stay in
        ~/Library/Application Support/Shepetal until you delete that folder.
      </p>
    ),
    text: 'Quit shepetal from the menu and drag it from Applications to the Trash. Your recordings and history stay in ~/Library/Application Support/Shepetal until you delete that folder.',
  },
  {
    q: 'What does it cost?',
    a: (
      <p>
        30 days free, with no card. Then $23.99 once, yours forever with updates included, or $0.99 a month, which you
        can cancel anytime on your <Link href="/account" prefetch={false}>account page</Link>, under Settings. You can
        also cancel without signing in: choose <Link href="/cancel" prefetch={false} lang="de">Verträge hier kündigen</Link>{' '}
        at the bottom of any page.
      </p>
    ),
    text: '30 days free, with no card. Then $23.99 once, yours forever with updates included, or $0.99 a month, which you can cancel anytime on your account page, under Settings. You can also cancel without signing in: choose Verträge hier kündigen at the bottom of any page.',
  },
  {
    q: 'Can I get a refund?',
    a: (
      <p>
        Yes. Write to <a href="mailto:support@shepetal.app">support@shepetal.app</a> within 14 days of buying the
        lifetime license for a full refund. A subscription stops charging the moment you cancel. The whole policy is
        on the <Link href="/refunds">refunds page</Link>.
      </p>
    ),
    text: 'Yes. Write to support@shepetal.app within 14 days of buying the lifetime license for a full refund. A subscription stops charging the moment you cancel.',
  },
  {
    q: 'Is there shepetal for Windows, Linux or iPhone?',
    a: (
      <p>
        Not yet. shepetal is for Mac today. Windows, Linux and iPhone are in the works, and they will be here when they
        are ready.
        {waitlistOn() && (
          <>
            {' '}
            <Link href="/waitlist" prefetch={false}>Join the waitlist</Link> and we will email you when yours is out.
          </>
        )}
      </p>
    ),
    text: `Not yet. shepetal is for Mac today. Windows, Linux and iPhone are in the works, and they will be here when they are ready.${waitlistOn() ? ' Join the waitlist and we will email you when yours is out.' : ''}`,
  },
  {
    q: 'Can I use it on more than one Mac?',
    a: <p>Yes. Your license belongs to your Google account, not to one Mac. Sign in with the same account on each Mac.</p>,
    text: 'Yes. Your license belongs to your Google account, not to one Mac. Sign in with the same account on each Mac.',
  },
];

export default function Faq() {
  const data = {
    '@context': 'https://schema.org',
    '@type': 'FAQPage',
    url: `${SITE_URL}/faq`,
    mainEntity: QAS.map((x) => ({ '@type': 'Question', name: x.q, acceptedAnswer: { '@type': 'Answer', text: x.text } })),
  };
  return (
    <>
      <SiteHeader end={<Link href="/account" prefetch={false}>Account</Link>} />
      <main className="s-main s-legal s-faq">
        <h1 className="s-h2">Questions.</h1>
        <div className="s-prose">
          {QAS.map((x) => (
            <section key={x.q} aria-labelledby={slug(x.q)}>
              <h2 id={slug(x.q)}>{x.q}</h2>
              {x.a}
            </section>
          ))}
          <p>
            Something else? Write to <a href="mailto:support@shepetal.app">support@shepetal.app</a>.
          </p>
        </div>
        <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(data).replace(/</g, '\\u003c') }} />
      </main>
    </>
  );
}

function slug(q: string) {
  return q.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
}
