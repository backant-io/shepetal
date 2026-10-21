import type { Metadata } from 'next';
import { Fragment } from 'react';
import { HeroDemo } from '@/components/HeroDemo';
import { Cycle, InView } from '@/components/landing/Cycle';
import { Icons, Ind, Shush, Win, Words } from '@/components/landing/Mac';
import { ShareBar } from '@/components/landing/ShareBar';
import { SignInButton } from '@/components/SignInButton';

export const metadata: Metadata = { alternates: { canonical: '/' } };

const TRY = 'Try 30 days free';
const NCVS = 'https://ncvs.org/archive/ncvs/tutorials/voiceprod/tutorial/quality.html';
// Typing: Karat et al., CHI 1999 (everyday computer users), and Dhakal et al., CHI 2018 (a large online typing test).
const KARAT = 'https://doi.org/10.1145/302979.303160';
const DHAKAL = 'https://doi.org/10.1145/3173574.3174220';

/** A footnote marker. The first marker of a note carries the id the note links back to. */
function Ref({ n, first }: { n: number; first?: boolean }) {
  return (
    <sup className="ref">
      <a href={`#note-${n}`} id={first ? `ref-${n}` : undefined} aria-label={`Note ${n}`}>
        {n}
      </a>
    </sup>
  );
}

/** A generated brand image: AVIF with a WebP fallback, in the widths that exist, and the night version in dark mode. */
function Photo({
  name,
  night,
  widths,
  alt,
  w,
  h,
  sizes,
  eager,
  className,
}: {
  name: string;
  night?: string;
  widths: number[];
  alt: string;
  w: number;
  h: number;
  sizes: string;
  eager?: boolean;
  className?: string;
}) {
  const set = (n: string, t: string) => widths.map((x) => `/brand/imagery/${n}-${x}.${t} ${x}w`).join(', ');
  return (
    <picture className={className}>
      {night && <source type="image/avif" srcSet={set(night, 'avif')} sizes={sizes} media="(prefers-color-scheme: dark)" />}
      {night && <source type="image/webp" srcSet={set(night, 'webp')} sizes={sizes} media="(prefers-color-scheme: dark)" />}
      <source type="image/avif" srcSet={set(name, 'avif')} sizes={sizes} />
      <img
        src={`/brand/imagery/${name}-${widths[widths.length - 1]}.webp`}
        srcSet={set(name, 'webp')}
        sizes={sizes}
        alt={alt}
        width={w}
        height={h}
        loading={eager ? 'eager' : 'lazy'}
        decoding="async"
        {...(eager ? { fetchPriority: 'high' as const } : {})}
      />
    </picture>
  );
}

/* ---------- Every app: five scenes ---------- */

function Stage({ label, mode, children }: { label: string; mode?: 'free'; children: React.ReactNode }) {
  return (
    <div className="stage" role="img" aria-label={`Illustration: ${label}`} data-mode={mode}>
      {children}
      <Ind />
      <span className="illus">Illustration</span>
    </div>
  );
}

const APP_TABS = [
  <Fragment key="mail">{Icons.mail} Mail</Fragment>,
  <Fragment key="chat">{Icons.chat} Chat</Fragment>,
  <Fragment key="code">{Icons.code} Code</Fragment>,
  <Fragment key="term">{Icons.term} Terminal</Fragment>,
  <Fragment key="docs">{Icons.doc} Docs</Fragment>,
];

const APP_SCENES = [
  <Fragment key="mail">
    <Stage label="A reply in a mail app. The ring turns red while you speak, blue while it writes, and the reply lands above the quoted message.">
      <Win title="Re: Invoice for October">
        <div className="field">
          <span>To:</span>
          <span>Luka Kos</span>
        </div>
        <div className="reply">
          <p>Hi Luka,</p>
          <p>
            <Words text="Thanks, I paid it this morning. The next one can go to the same address." delay="1.6s" />
          </p>
          <div className="quote">
            <p>On 20.10.26 Luka Kos wrote:</p>
            <p>Hi Maja, here is the invoice for October. Let me know if anything is missing.</p>
          </div>
        </div>
      </Win>
    </Stage>
    <p className="scene-cap">A reply in your mail app, written while you look at the invoice.</p>
  </Fragment>,
  <Fragment key="chat">
    <Stage label="A team chat. The message lands in the box at the bottom.">
      <Win title="#launch">
        <div className="chat">
          <div className="chat-side">
            <span># general</span>
            <span className="on"># launch</span>
            <span># design</span>
            <span>Maja Novak</span>
            <span>Luka Kos</span>
          </div>
          <div className="chat-main">
            <div className="msg">
              <span className="av">LK</span>
              <div>
                <b>Luka</b> <small>09:12</small>
                <p>Is everyone ready for the beta call at three?</p>
              </div>
            </div>
            <div className="msg">
              <span className="av av-b">AP</span>
              <div>
                <b>Ana</b> <small>09:14</small>
                <p>Almost, fixing the last screenshot.</p>
              </div>
            </div>
            <div className="composer">
              <Words text="Running ten minutes late, start without me and I’ll catch up." delay="1.6s" />
            </div>
          </div>
        </div>
      </Win>
    </Stage>
    <p className="scene-cap">A message in your team chat, in the box you were already typing in.</p>
  </Fragment>,
  <Fragment key="code">
    <Stage label="A code editor. A comment lands on the line where the cursor was.">
      <Win title="upload.ts">
        <div className="code">
          <div>
            <i>1</i>
            <span>
              <span className="tok-k">import</span> {'{ send }'} <span className="tok-k">from</span> <span className="tok-s">&apos;./net&apos;</span>;
            </span>
          </div>
          <div>
            <i>2</i>
            <span />
          </div>
          <div>
            <i>3</i>
            <span>
              <span className="tok-k">export async function</span> <span className="tok-f">upload</span>(file: File) {'{'}
            </span>
          </div>
          <div className="code-hl">
            <i>4</i>
            <span className="tok-c">
              {'  // '}
              <Words text="Try three times with a short pause before you show the error." delay="1.6s" />
            </span>
          </div>
          <div>
            <i>5</i>
            <span>
              {'  '}
              <span className="tok-k">for</span> (<span className="tok-k">let</span> i = 0; i &lt; 3; i++) {'{'}
            </span>
          </div>
          <div>
            <i>6</i>
            <span>
              {'    '}
              <span className="tok-k">const</span> res = <span className="tok-k">await</span> <span className="tok-f">send</span>(file);
            </span>
          </div>
          <div>
            <i>7</i>
            <span>
              {'    '}
              <span className="tok-k">if</span> (res.ok) <span className="tok-k">return</span> res;
            </span>
          </div>
          <div>
            <i>8</i>
            <span>{'  }'}</span>
          </div>
          <div>
            <i>9</i>
            <span>
              {'  '}
              <span className="tok-k">throw new</span> <span className="tok-f">Error</span>(<span className="tok-s">&apos;Upload failed&apos;</span>);
            </span>
          </div>
          <div>
            <i>10</i>
            <span>{'}'}</span>
          </div>
        </div>
      </Win>
    </Stage>
    <p className="scene-cap">A comment in your code editor, on the line where the cursor was.</p>
  </Fragment>,
  <Fragment key="term">
    <Stage label="A terminal. A long prompt for a coding agent lands at the prompt in full sentences.">
      <Win title="~/shop" className="term-win">
        <div className="term">
          <p className="term-dim">~/shop on main</p>
          <p className="term-dim">Ready. Describe the change.</p>
          <p className="term-line">
            <span className="term-ps">›</span>
            <span>
              <Words
                text="Add a retry to the upload in upload.ts. Try three times with a short pause, show the error only after the last try, and keep the tests passing."
                delay="1.6s"
              />
            </span>
          </p>
        </div>
      </Win>
    </Stage>
    <p className="scene-cap">A whole prompt for your coding agent, in the terminal, with every detail you would skip when typing.</p>
  </Fragment>,
  <Fragment key="docs">
    <Stage mode="free" label="A doc in the browser. Hands-free: the ring is orange while you speak, then the paragraph lands.">
      <Win bar={<span className="browser-bar">Launch notes</span>}>
        <div className="doc">
          <h4>Launch notes</h4>
          <p>Beta on Friday. Release notes go out on 23.10.26.</p>
          <p>
            <Words
              text="The first testers get the build on Friday morning. Ask them to use it in the apps they open every day, and write down anything that felt slow."
              delay="2.6s"
            />
          </p>
        </div>
      </Win>
    </Stage>
    <p className="scene-cap">
      A longer paragraph in a doc. Double-tap <span className="kbd">fn</span> to speak hands-free: the ring stays orange until you tap{' '}
      <span className="kbd">fn</span> again.
    </p>
  </Fragment>,
];

/* ---------- Meetings: three steps ---------- */

const MEET_TABS = [
  <Fragment key="card">
    <span className="n">1</span>
    <span className="step-t">A call starts</span>
    <span className="s">A small card next to the indicator asks first. If you ignore it, nothing records.</span>
  </Fragment>,
  <Fragment key="live">
    <span className="n">2</span>
    <span className="step-t">You click Record</span>
    <span className="s">The ring stays red for the whole call, and the transcript fills in as Me and Others.</span>
  </Fragment>,
  <Fragment key="sum">
    <span className="n">3</span>
    <span className="step-t">After the call</span>
    <span className="s">A summary with key points, decisions and action items, written on your Mac.</span>
  </Fragment>,
];

const tiles = (
  <div className="call-grid">
    {[
      ['MN', 'Maja Novak'],
      ['LK', 'Luka Kos'],
      ['AP', 'Ana Petek'],
      ['', 'You'],
    ].map(([i, n]) => (
      <div key={n} className="tile">
        <span>{i || '·'}</span>
        <small>{n}</small>
      </div>
    ))}
  </div>
);

const MEET_SCENES = [
  <div
    key="card"
    className="stage ring-meet"
    role="img"
    aria-label="Illustration: a video call. A card above the 🤫 indicator says Meeting detected, zoom.us, with the buttons Record and Not now. Record is clicked, the card goes away and the ring turns red."
  >
    <Win title="Weekly sync" className="call">
      {tiles}
    </Win>
    <div className="card">
      <span>Meeting detected · zoom.us</span>
      <span className="b b-rec">Record</span>
      <span className="b">Not now</span>
    </div>
    <Ind hint={<span className="ind-hint hint-meet">Recording meeting</span>} />
    <span className="illus">Illustration</span>
  </div>,
  <div
    key="live"
    className="stage always-red"
    role="img"
    aria-label="Illustration: the meeting transcript, live. Lines from Others and from Me appear in turn while the ring stays red."
  >
    <Win title="shepetal">
      <div className="hub-main live-main">
        <p className="hub-meta">
          zoom.us · 21.10.26 15:00 <span className="live">Live</span>
        </p>
        {[
          ['Others · 0:03', 'Shall we ship the beta on Friday?', ''],
          ['Me · 0:09', 'Yes. I’ll send the release notes tomorrow.', 'me'],
          ['Others · 0:15', 'Good, then I’ll book the review for Monday.', ''],
          ['Me · 0:21', 'Monday works. I’ll bring the test results.', 'me'],
        ].map(([cap, text, who], i) => (
          <div key={cap} className={`line ${who}`} style={{ '--i': i } as React.CSSProperties}>
            <small>{cap}</small>
            {text}
          </div>
        ))}
      </div>
    </Win>
    <Ind />
    <span className="illus">Illustration</span>
  </div>,
  <div
    key="sum"
    className="stage"
    role="img"
    aria-label="Illustration: the Meetings tab in shepetal. A list of calls, and the summary of the zoom.us call with an overview, key points, a decision and two action items."
  >
    <Win title="shepetal">
      <div className="hub">
        <div className="hub-side">
          <div className="hub-row on">
            zoom.us<small>21.10.26 · 42 min</small>
          </div>
          <div className="hub-row">
            Google Chrome<small>20.10.26 · 18 min</small>
          </div>
          <div className="hub-row">
            FaceTime<small>17.10.26 · 9 min</small>
          </div>
        </div>
        <div className="hub-main sum">
          <div className="seg" style={{ '--i': 0 } as React.CSSProperties}>
            <span className="on">Summary</span>
            <span>Transcript</span>
          </div>
          <div style={{ '--i': 1 } as React.CSSProperties}>
            <h5>Overview</h5>
            <p>The team agreed to ship the beta on Friday and review it on Monday.</p>
          </div>
          <div style={{ '--i': 2 } as React.CSSProperties}>
            <h5>Decisions</h5>
            <p>Ship the beta on Friday.</p>
          </div>
          <div style={{ '--i': 3 } as React.CSSProperties}>
            <h5>Action items</h5>
            <table>
              <tbody>
                <tr>
                  <td>Me</td>
                  <td>Send the release notes</td>
                  <td>22.10.26</td>
                </tr>
                <tr>
                  <td>Luka</td>
                  <td>Book the review</td>
                  <td>27.10.26</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </Win>
    <Ind />
    <span className="illus">Illustration</span>
  </div>,
];

/* ---------- FAQ ---------- */

const FAQ: [string, React.ReactNode][] = [
  [
    'Does it work offline?',
    'Yes. Speech recognition runs on your Mac, so dictation works with the Wi-Fi off, on a plane or on a train with no signal. The license needs a connection once every 7 days.',
  ],
  [
    'Where does my voice go?',
    'It stays on your Mac. Speech recognition runs on the Mac, and your recordings and history are saved in a folder on it that only your user account can read. The text you dictate goes wherever the app you paste it into sends it.',
  ],
  [
    'Why do I sign in with Google?',
    'For the license. Signing in starts your 30 days and connects your purchase to you, so the account knows your email address. Your audio and your text are never part of it.',
  ],
  [
    'What happens after 30 days?',
    'You can keep shepetal with a single payment of $4.99. It is yours, with updates. The trial needs no card, so nothing is charged on its own.',
  ],
  [
    'Which Macs does it run on?',
    'Macs with Apple silicon on macOS 14.4 or later. Speech recognition downloads once, about 470 MB.',
  ],
  [
    'Does it work in the terminal and in code editors?',
    'Yes. Your words land wherever your cursor is: the terminal, your code editor, the chat with your coding agent, mail, notes or a doc in the browser.',
  ],
  [
    'Does it make sounds?',
    <>
      No. The app makes no sounds. The <Shush /> in the bottom-left corner of your screen shows what it is doing: a red ring while it
      records, orange in hands-free and a pulsing blue ring while it writes.
    </>,
  ],
  [
    'Who knows a meeting is being recorded?',
    <>
      You decide. A meeting records only after you click Record on the card next to <Shush />, and recording automatically is off until
      you turn it on in Settings. Let people know before you record them.
    </>,
  ],
  ['Is there a version for Linux, Windows or iPhone?', 'All three are in development. No dates yet.'],
  [
    'What does the name mean?',
    'It comes from a Slovenian word for “he whispered” or “she whispered”. Pavel, who makes shepetal, is from Slovenia.',
  ],
];

export default function Home() {
  return (
    <main className="lp">
      {/* Hero */}
      <section className="hero grain" aria-labelledby="hero-title">
        <div className="wrap">
          <div className="hero-top">
            <h1 id="hero-title" className="t-display hero-title">
              <Words text="Effortless voice-to-text that transforms the way you work." />
              <Ref n={1} first />
            </h1>
            <div className="hero-copy">
              <p className="t-lead">
                Press one key. Your words appear wherever you speak, about 0.1 s after you finish, and your voice stays on your Mac.
              </p>
              <div className="cta-row" id="hero-cta">
                <SignInButton redirectTo="/account" className="btn btn-lg">
                  {TRY}
                </SignInButton>
                <a href="#price" className="btn btn-quiet btn-lg">
                  $4.99 once
                </a>
              </div>
              <p className="hero-meta">
                Google sign-in, only for the license · no card
                <br />
                For Mac with Apple silicon, macOS 14.4 or later
              </p>
            </div>
          </div>
          <HeroDemo
            wallpaper={
              <Photo
                name="last-light"
                night="dusk-air"
                widths={[800, 1600, 2400]}
                alt=""
                w={2400}
                h={1357}
                eager
                className="wallpaper"
                sizes="(min-width: 1280px) 1200px, 100vw"
              />
            }
          />
          <ul className="legend" aria-label="What the ring around the indicator means">
            <li>
              <Ind state="rec" className="static" />
              Recording
            </li>
            <li>
              <Ind state="free" className="static" />
              Hands-free
            </li>
            <li>
              <Ind state="write" className="static" />
              Writing
            </li>
          </ul>
        </div>
      </section>

      {/* Facts that anyone can check, in the place other pages put logos */}
      <div className="wrap">
        <ul className="facts" aria-label="shepetal in short">
          <li>
            <b>About 0.1 s</b>
            <span>from letting go to text, M4 Pro</span>
          </li>
          <li>
            <b>Wi-Fi off</b>
            <span>dictation keeps working</span>
          </li>
          <li>
            <b>$4.99 once</b>
            <span>after 30 days free</span>
          </li>
          <li>
            <b>No sounds</b>
            <span>the indicator shows the state</span>
          </li>
          <li>
            <b>No trackers</b>
            <span>on this page, fonts served from here</span>
          </li>
        </ul>
      </div>

      {/* Every app */}
      <section id="apps" className="sec" aria-labelledby="apps-title">
        <div className="wrap">
          <div className="head">
            <h2 id="apps-title" className="t-h1">
              Press one key. Your words appear wherever you speak.
            </h2>
            <p className="t-lead muted">
              Mail, chat, your code editor, the terminal and docs in the browser. The text lands where your cursor is, in the app you were
              already using.
            </p>
          </div>

          <div className="apps">
            <Cycle label="Apps" tabs={APP_TABS} panels={APP_SCENES} ms={7000} />
          </div>

          <div className="two">
            <div>
              <h3 className="t-h3">For builders</h3>
              <p className="t-body">
                Say the whole prompt. Describe the change to your coding agent in full sentences, in the terminal or in your editor, with the
                detail you would leave out when typing. Speech recognition runs on your Mac, so the code, client names and plans you mention
                stay on it until you send the prompt.
              </p>
            </div>
            <div>
              <h3 className="t-h3">For every day</h3>
              <p className="t-body">
                Replies, messages and notes with one key, in the apps you already use. On a train with no signal it works the same, and when
                a thought gets longer, double-tap <span className="kbd">fn</span> and speak hands-free.
              </p>
            </div>
          </div>
        </div>
      </section>

      {/* Speed */}
      <section className="sec speed-sec" aria-labelledby="speed-title">
        <div className="wrap">
          <InView className="speed">
            <h2 id="speed-title" className="big-num">
              <span className="pre">About</span>0.1<span className="unit"> s</span>
            </h2>
            <p className="t-lead">
              From letting go of <span className="kbd">fn</span> to the text in your app, measured on an M4 Pro.
              <Ref n={3} first /> Speech recognition runs on your Mac, so the text is ready the moment you finish speaking.
            </p>
            <figure className="ruler" aria-label="A timeline from 0 to 1 second. You let go at 0. The text is there between 57 and 89 milliseconds, 69 on average.">
              <div className="ruler-track" aria-hidden="true">
                <span className="ruler-band" />
                <span className="ruler-dot" />
                {[0, 0.25, 0.5, 0.75, 1].map((t) => (
                  <span key={t} className="ruler-tick" style={{ '--x': t } as React.CSSProperties}>
                    <span>{t === 0 ? '0 s' : t === 1 ? '1 s' : `${t * 1000} ms`}</span>
                  </span>
                ))}
              </div>
              <figcaption>
                <span>
                  <b>You let go</b> at 0
                </span>
                <span>
                  <b>The text is there</b> after 57 to 89 ms, 69 ms on average
                </span>
              </figcaption>
            </figure>
          </InView>

          <InView className="wpm">
            <div>
              <h3 className="t-h3">
                Instant, real-time, 4x faster.
                <Ref n={4} first />
              </h3>
              <p className="t-body muted">Speaking is about 4x faster than typing: about 150 words a minute against about 40.</p>
            </div>
            <div className="rates">
              <div className="rate">
                <span>Speaking</span>
                <b>about 150 words a minute</b>
                <span className="rate-bar" aria-hidden="true">
                  <i style={{ '--w': '100%' } as React.CSSProperties} />
                </span>
              </div>
              <div className="rate rate-type">
                <span>Typing</span>
                <b>about 40 words a minute</b>
                <span className="rate-bar" aria-hidden="true">
                  <i style={{ '--w': `${(40 / 150) * 100}%` } as React.CSSProperties} />
                </span>
              </div>
              <p className="source">
                Speaking rate from the{' '}
                <a href={NCVS} rel="noopener">
                  US National Center for Voice and Speech
                </a>
                . Typing rate of the fast typists in a study of everyday computer users (
                <a href={KARAT} rel="noopener">
                  Karat et al., CHI 1999
                </a>
                ). Your own gain depends on how fast you type.
              </p>
            </div>
          </InView>
        </div>
      </section>

      {/* Privacy and offline: the dusk band */}
      <section id="privacy" className="night grain" aria-labelledby="privacy-title">
        <div className="wrap sec privacy">
          <div className="privacy-copy">
            <h2 id="privacy-title" className="t-h1">
              100% private. Your data is yours.
              <Ref n={2} first />
            </h2>
            <p className="t-lead">
              Your voice and your text stay on your Mac. Speech recognition runs on the Mac, so dictation keeps working with the <span className="nw">Wi-Fi</span> off.
            </p>
            <p className="t-body muted">
              Cloud dictation sends your voice to a server to turn it into text. shepetal does that work on your Mac, and that is how it is
              built.
            </p>
            <div className="online">
              <p className="t-small">shepetal goes online for four things, and none of them carries your audio or your text:</p>
              <ul>
                <li>signing in with Google</li>
                <li>the license check, at launch and once a day, never while you dictate</li>
                <li>checkout</li>
                <li>the one-time speech recognition download, about 470 MB</li>
              </ul>
            </div>
            <div className="cta-row">
              <SignInButton redirectTo="/account" className="btn btn-lg">
                {TRY}
              </SignInButton>
              <a href="/privacy" className="link">
                Read the privacy details
              </a>
            </div>
          </div>
          <InView className="offline-wrap">
            <div
              className="offline"
              role="img"
              aria-label="Illustration: on a train at dusk, the Wi-Fi is switched off in Control Center. A dictation still runs: the ring turns red, then blue, and the text lands in a note."
            >
              <Photo name="train" widths={[800, 1400]} alt="" w={1400} h={930} sizes="(min-width: 960px) 600px, 100vw" />
              <div className="cc" aria-hidden="true">
                <div className="cc-row cc-wifi">
                  <span className="cc-dot">{Icons.wifi}</span>
                  <span>
                    Wi-Fi
                    <small className="cc-state" />
                  </span>
                </div>
                <div className="cc-row">
                  <span className="cc-dot">{Icons.moon}</span>
                  <span>
                    Focus
                    <small>Off</small>
                  </span>
                </div>
              </div>
              <Win title="Notes" className="notes-win">
                <div className="notes-body">
                  <p className="notes-t">Train to Ljubljana</p>
                  <p>
                    <Words text="Draft the welcome email for the testers and keep it short." delay="3.4s" />
                  </p>
                </div>
              </Win>
              <Ind />
              <span className="illus">Illustration</span>
            </div>
            <p className="scene-cap">Wi-Fi off on the train, and the note still lands.</p>
          </InView>
        </div>
      </section>

      {/* Meetings */}
      <section id="meetings" className="sec" aria-labelledby="meet-title">
        <div className="wrap">
          <div className="head">
            <h2 id="meet-title" className="t-h1">
              It asks before it records.
            </h2>
            <p className="t-lead muted">
              When a call starts in Zoom, Google Meet, Teams or another call app, a small card next to the indicator asks first. Click Record and
              focus on the conversation. The transcript and the summary are in Meetings.
            </p>
            <p className="t-body muted">
              Recording automatically is a setting, and it is off until you turn it on. Let people know before you record them.
            </p>
          </div>
          <div className="meet">
            <Cycle label="How a meeting is recorded" tabs={MEET_TABS} panels={MEET_SCENES} ms={6500} tabClass="step-tab" />
          </div>
        </div>
      </section>

      {/* Recordings */}
      <section className="sec rec-sec" aria-labelledby="rec-title">
        <div className="wrap rec">
          <div className="head">
            <h2 id="rec-title" className="t-h1">
              Your recordings stay on your Mac.
            </h2>
            <p className="t-lead muted">
              Every recording, transcript and summary is saved in a folder on your Mac that only your user account can read. Keep them, or
              choose Delete recordings after 24 hours in Settings.
            </p>
          </div>
          <InView className="settings-wrap">
            <div
              className="settings"
              role="img"
              aria-label="Illustration: shepetal Settings. The Recordings menu is open with two choices, Keep recordings and Delete recordings after 24 hours, and the second one is picked."
            >
              <Win title="shepetal">
                <div className="set-tabs" aria-hidden="true">
                  <span>Home</span>
                  <span>History</span>
                  <span>Meetings</span>
                  <span className="on">Settings</span>
                </div>
                <div className="set-form" aria-hidden="true">
                  <div className="set-row">
                    <span>Recordings</span>
                    <span className="popup">
                      <span className="popup-a">Keep recordings</span>
                      <span className="popup-b">Delete recordings after 24 hours</span>
                    </span>
                  </div>
                  <div className="set-menu">
                    <span className="m-keep">Keep recordings</span>
                    <span className="m-del">Delete recordings after 24 hours</span>
                  </div>
                  <div className="set-row">
                    <span>Record meetings automatically</span>
                    <span className="switch" />
                  </div>
                  <p className="set-note">A detected meeting records only after you click Record next to the indicator.</p>
                </div>
              </Win>
            </div>
          </InView>
        </div>
      </section>

      {/* Small details */}
      <section className="sec details-sec" aria-labelledby="details-title">
        <div className="wrap">
          <h2 id="details-title" className="t-h2">
            Quiet by design
          </h2>
          <ul className="details">
            <li>
              <h3 className="t-h4">No sounds</h3>
              <p>
                The app makes no sounds. The <Shush /> in the bottom-left corner of your screen shows what it is doing, in 18 points of space.
              </p>
            </li>
            <li>
              <h3 className="t-h4">Dates as numbers</h3>
              <p>Say “the twenty-sixth of July” and it lands as 26.07.26.</p>
            </li>
            <li>
              <h3 className="t-h4">Hands-free</h3>
              <p>
                Double-tap <span className="kbd">fn</span> to speak without holding the key. Tap <span className="kbd">fn</span> once to finish.
              </p>
            </li>
            <li>
              <h3 className="t-h4">On every Space</h3>
              <p>The indicator stays in its corner on every desktop and over full-screen apps, and clicks go through it.</p>
            </li>
          </ul>
        </div>
      </section>

      {/* The name, and the maker */}
      <section id="story" className="sec story-sec" aria-labelledby="name-title">
        <div className="wrap story">
          <figure className="story-photo">
            <Photo
              name="valley"
              widths={[800, 1400]}
              alt="A turquoise river in a green alpine valley at the end of the day"
              w={1400}
              h={1750}
              sizes="(min-width: 960px) 480px, 100vw"
            />
          </figure>
          <div className="story-copy">
            <h2 id="name-title" className="sr">
              The name
            </h2>
            <p className="word">
              <span lang="sl">šepetal</span>
              <span className="word-gloss">Slovenian for “he whispered” or “she whispered”</span>
            </p>
            <div className="reading">
              <p>
                You probably write the same kind of reply over and over during the day, and you already know what you want to say long before
                your hands catch up. I have built shepetal so you can press one key and just say it, and the text lands wherever your cursor is.
              </p>
              <p>
                It all runs on your Mac, because I wanted my own voice to stay on mine, and it makes no sound. The little indicator in the
                corner shows you what it is doing. Meetings work the same way: it asks first, and the transcript stays with you.
              </p>
              <p>
                shepetal is new, so if you start now you are one of the first people using it, and every update after you buy it is yours
                too.
              </p>
            </div>
            <p className="sign">
              <b>Pavel Hegler</b>
              Maker of shepetal, Slovenia
            </p>
          </div>
        </div>
      </section>

      {/* Price */}
      <section id="price" className="sec price-sec" aria-labelledby="price-title">
        <div className="wrap">
          <div className="price">
            <div className="price-card">
              <h2 id="price-title" className="t-h1">
                $4.99, once.
              </h2>
              <p className="t-lead">30 days free, no card. Then $4.99 once, with updates.</p>
              <p className="t-body muted">
                Speech recognition runs on your Mac, so no server has to do the work for every word you say, and the price reflects that.
              </p>
              <div className="cta-row">
                <SignInButton redirectTo="/account" className="btn btn-lg">
                  {TRY}
                </SignInButton>
                <span className="t-small muted">Sign in with Google to start the trial</span>
              </div>
            </div>
            <table className="compare">
              <caption>shepetal next to cloud dictation subscriptions</caption>
              <thead>
                <tr>
                  <td />
                  <th scope="col">shepetal</th>
                  <th scope="col">Cloud dictation subscriptions</th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <th scope="row">You pay</th>
                  <td>$4.99 once, updates included</td>
                  <td>Every month or every year</td>
                </tr>
                <tr>
                  <th scope="row">Speech recognition</th>
                  <td>On your Mac</td>
                  <td>On the provider’s servers</td>
                </tr>
                <tr>
                  <th scope="row">With the Wi-Fi off</th>
                  <td>Dictation keeps working</td>
                  <td>Needs a connection</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      {/* Platforms */}
      <section className="sec plat-sec" aria-labelledby="plat-title">
        <div className="wrap plat-grid">
          <div className="head">
            <h2 id="plat-title" className="t-h2">
              Mac now
            </h2>
            <p className="t-body muted">Linux, Windows and iPhone are in development. No dates yet.</p>
          </div>
          <ul className="plats">
            <li className="plat plat-now">
              <b>Mac</b>
              <span>Available now · macOS 14.4 or later, Apple silicon</span>
            </li>
            <li className="plat">
              <b>Linux</b>
              <span>In development</span>
            </li>
            <li className="plat">
              <b>Windows</b>
              <span>In development</span>
            </li>
            <li className="plat">
              <b>iPhone</b>
              <span>In development</span>
            </li>
          </ul>
        </div>
      </section>

      {/* FAQ */}
      <section id="faq" className="sec faq-sec" aria-labelledby="faq-title">
        <div className="wrap faq-grid">
          <h2 id="faq-title" className="t-h2">
            Questions
          </h2>
          <div className="faq">
            {FAQ.map(([q, a]) => (
              <details key={q}>
                <summary>{q}</summary>
                <div>{a}</div>
              </details>
            ))}
          </div>
        </div>
      </section>

      {/* The last light: the page's one Mulberry field */}
      <section className="final grain" aria-labelledby="final-title">
        <div className="wrap">
          <img className="final-mark" src="/brand/shepetal-wordmark-on-dark.svg" alt="shepetal" width={320} height={86} loading="lazy" />
          <h2 id="final-title" className="t-h1">
            Instant dictation that stays on your Mac.
          </h2>
          <p className="t-lead">
            Dictation and meetings in one app on your Mac. 30 days free, no card. Then $4.99 once, with updates. Be one of the first to use it.
          </p>
          <div className="cta-row">
            <SignInButton redirectTo="/account" className="btn btn-lg">
              {TRY}
            </SignInButton>
          </div>
          <p className="final-meta">Google sign-in, only for the license · For Mac with Apple silicon, macOS 14.4 or later</p>
        </div>
      </section>

      {/* Notes: the proof for the approved lines (brand voice, Approved lines) */}
      <section className="notes" aria-labelledby="notes-title">
        <div className="wrap">
          <h2 id="notes-title" className="t-small">
            Notes
          </h2>
          <ol>
            <li id="note-1">
              Hold fn to dictate, double-tap fn for hands-free, tap fn once to stop. The text lands in any app you can type in, after a
              one-time setup: the permissions, a Google sign-in and one download. <a href="#ref-1">Back</a>
            </li>
            <li id="note-2">
              “100% private” means your voice and your text: speech recognition runs on your Mac, and shepetal never sends your audio or your
              text anywhere. Your recordings, transcripts and history are stored on the Mac in a folder only your user account can read. The
              text you dictate goes wherever the app you paste it into sends it. shepetal goes online for four things, and none of them
              carries audio or text: sign-in, the license check (at launch and once a day, never while you dictate), checkout, and the
              one-time speech recognition download of about 470 MB. Your account (your Google email address and your license status) is kept
              by shepetal’s account service, and payment is handled by the payment provider. Dictation works with the Wi-Fi off; the license
              needs a connection once every 7 days. Meeting summaries are written on the Mac. <a href="#ref-2">Back</a>
            </li>
            <li id="note-3">
              About 0.1 s from letting go of fn to the text: 57 to 89 ms (69 ms on average) on six synthesized clips of 4.5 to 10.7 s, with
              the default speech recognition, on an M4 Pro, network blocked, October 20, 2026. Longer dictations, other Macs and the
              alternative speech recognition take longer. Real-time means the text is ready the moment you finish speaking, with nothing uploaded.{' '}
              <a href="#ref-3">Back</a>
            </li>
            <li id="note-4">
              Speaking runs at about 150 words per minute (
              <a href={NCVS} rel="noopener">
                US National Center for Voice and Speech
              </a>
              ). In a study of everyday computer users, people typed 32.5 words per minute when they copied text, 40 for the fast typists among them, and
              19 when they wrote their own words (
              <a href={KARAT} rel="noopener">
                Karat et al., CHI 1999
              </a>
              ). We use 40: 150 ÷ 40 = 3.75, rounded to 4x. In a large online typing test, people copying sentences averaged about 52 words
              per minute (
              <a href={DHAKAL} rel="noopener">
                Dhakal et al., CHI 2018
              </a>
              ), and next to that speaking is about 3x faster. Your own gain depends on how fast you type and how much you correct.{' '}
              <a href="#ref-4">Back</a>
            </li>
          </ol>
        </div>
      </section>

      <ShareBar />
    </main>
  );
}
