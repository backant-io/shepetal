import type { Metadata } from 'next';
import { pageMetadata } from '@/lib/seo';
import Link from 'next/link';
import { SiteHeader } from '@/components/site/Shell';

export const metadata: Metadata = pageMetadata('press', { title: 'Press', description: 'The name, the facts, the boilerplate, the logo and screenshots of shepetal, dictation for Mac.' });

const LOGOS = [
  { file: 'shepetal-wordmark-ink', what: 'Wordmark, ink on light', formats: ['svg', 'png'], dark: false },
  { file: 'shepetal-wordmark-light', what: 'Wordmark, light on dark', formats: ['svg', 'png'], dark: true },
  { file: 'shepetal-fn-key', what: 'The fn key', formats: ['png'], dark: false },
  { file: 'shepetal-icon-512', what: 'App icon (Noto Emoji, Apache 2.0)', formats: ['png'], dark: false },
];

const SCREENS = [
  { file: 'site-hero', alt: 'The shepetal site: "Press one key." beside the orange fn key, and "Your words appear wherever you speak."' },
  { file: 'site-every-app', alt: 'The shepetal site: "Works in every app." with a sentence written into mail, chat, code, a terminal and notes.' },
  { file: 'site-private', alt: 'The shepetal site: "100% private. Your data is yours." with a note written while offline.' },
  { file: 'site-meetings', alt: 'The shepetal site: "Meetings, transcribed on your Mac." with a meeting reminder and three transcript lines.' },
];

export default function Press() {
  return (
    <>
      <SiteHeader end={<Link href="/account" prefetch={false}>Account</Link>} />
      <main className="s-main s-legal s-press">
        <h1 className="s-h2">Press.</h1>
        <p className="s-mono">For writers, editors and podcasters</p>

        <div className="s-prose">
          <h2>The name</h2>
          <p className="s-press-name">šepetal (Slovene): he whispered.</p>
          <p>
            Written shepetal, always lowercase. You speak, the Mac writes, and nothing you say leaves the room.
          </p>

          <h2>In one line</h2>
          <p>shepetal is dictation for Mac: press one key, and your words appear wherever you speak.</p>

          <h2>Boilerplate</h2>
          <p>
            shepetal is dictation for Mac. One key, and the words you speak appear wherever the cursor is, in any app:
            mail, chat, code, a terminal or a note. Speech recognition runs on the Mac itself, so your voice never
            leaves it, and it needs no internet. shepetal also transcribes meetings on the
            Mac. It runs on Macs with Apple silicon and macOS 14.4 or later, in 25 European languages. It is free for
            30 days, then $23.99 once or $0.99 a month. shepetal is made by BackAnt, Inc.
          </p>

          <h2>Facts</h2>
          <ul>
            <li>Platform: macOS 14.4 or later, Apple silicon.</li>
            <li>Price: 30 days free with no card, then $23.99 once or $0.99 a month.</li>
            <li>Languages: 25 European languages.</li>
            <li>Privacy: your voice never leaves your Mac.</li>
            <li>Website: shepetal.app</li>
            <li>Maker: BackAnt, Inc. (Delaware, USA)</li>
          </ul>

          <h2>Logo</h2>
          <p>Use the files as they are: no recoloring, no outlines, and no emoji next to the wordmark.</p>
        </div>

        <ul className="s-press-files">
          {LOGOS.map((l) => (
            <li key={l.file}>
              <div className={l.dark ? 's-press-swatch s-press-dark' : 's-press-swatch'}>
                <img src={`/press/${l.file}.png`} alt={l.what} loading="lazy" />
              </div>
              <p className="s-mono">
                {l.what}:{' '}
                {l.formats.map((f, i) => (
                  <span key={f}>
                    {i > 0 && ' · '}
                    <a href={`/press/${l.file}.${f}`} download>
                      {f.toUpperCase()}
                    </a>
                  </span>
                ))}
              </p>
            </li>
          ))}
        </ul>

        <div className="s-prose">
          <h2>Screenshots</h2>
          <p>The site at 1440 × 900. Click one for the full size.</p>
        </div>
        <ul className="s-press-shots">
          {SCREENS.map((s) => (
            <li key={s.file}>
              <a href={`/press/${s.file}.jpg`}>
                <img src={`/press/${s.file}.jpg`} alt={s.alt} width={1440} height={900} loading="lazy" />
              </a>
            </li>
          ))}
        </ul>

        <div className="s-prose">
          <h2>Contact</h2>
          <p>
            Pavel Hegler, <a href="mailto:support@shepetal.app">support@shepetal.app</a>. Try it yourself: 30 days free,
            from the <Link href="/">home page</Link>.
          </p>
        </div>
      </main>
    </>
  );
}
