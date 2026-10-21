import type { Metadata } from 'next';
import { Fragment } from 'react';
import { Cycle, InView } from '@/components/landing/Cycle';
import { Hero, TRY } from '@/components/landing/Hero';
import { Icons, Ind, Shush, Win, Words } from '@/components/landing/Mac';
import { SendToMac, ShareBar } from '@/components/landing/ShareBar';
import { SignInButton } from '@/components/SignInButton';

export const metadata: Metadata = { alternates: { canonical: '/' } };

/** A generated brand image: AVIF with a WebP fallback, in the widths that exist, and the night version in dark mode.
 * `webp` for the images whose WebP came out smaller than the AVIF (last-light, valley). */
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
  webp,
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
  webp?: boolean;
}) {
  const set = (n: string, t: string) => widths.map((x) => `/brand/imagery/${n}-${x}.${t} ${x}w`).join(', ');
  return (
    <picture className={className}>
      {night && <source type="image/avif" srcSet={set(night, 'avif')} sizes={sizes} media="(prefers-color-scheme: dark)" />}
      {night && <source type="image/webp" srcSet={set(night, 'webp')} sizes={sizes} media="(prefers-color-scheme: dark)" />}
      {!webp && <source type="image/avif" srcSet={set(name, 'avif')} sizes={sizes} />}
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
    <p className="scene-cap">A reply in your mail app.</p>
  </Fragment>,
  <Fragment key="chat">
    <Stage label="A team chat. The message lands in the box at the bottom.">
      <Win title="#studio">
        <div className="chat">
          <div className="chat-side">
            <span># general</span>
            <span className="on"># studio</span>
            <span># design</span>
            <span>Maja Novak</span>
            <span>Luka Kos</span>
          </div>
          <div className="chat-main">
            <div className="msg">
              <span className="av">LK</span>
              <div>
                <b>Luka</b> <small>09:12</small>
                <p>Is everyone ready for the client call at three?</p>
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
    <p className="scene-cap">A message in your team chat.</p>
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
    <p className="scene-cap">A comment in your code editor.</p>
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
    <p className="scene-cap">A whole prompt for your coding agent.</p>
  </Fragment>,
  <Fragment key="docs">
    <Stage mode="free" label="A doc in the browser. Hands-free: the ring is orange while you speak, then the paragraph lands.">
      <Win bar={<span className="browser-bar">Handover notes</span>}>
        <div className="doc">
          <p className="doc-h">Handover notes</p>
          <p>The new site goes to the client on 23.10.26.</p>
          <p>
            <Words
              text="Walk them through the editor first, then the invoices, and leave time at the end for their questions. Send the checklist the day before."
              delay="2.6s"
            />
          </p>
        </div>
      </Win>
    </Stage>
    <p className="scene-cap">A long paragraph in a doc, hands-free. The ring stays orange while you speak.</p>
  </Fragment>,
];

/* ---------- Meetings: three steps ---------- */

const MEET_TABS = [
  <Fragment key="card">
    <span className="n">1</span>
    <span className="step-t">A call starts</span>
    <span className="s">A card asks first. Nothing records until you click.</span>
  </Fragment>,
  <Fragment key="live">
    <span className="n">2</span>
    <span className="step-t">You click Record</span>
    <span className="s">The ring stays red. The transcript fills in as Me and Others.</span>
  </Fragment>,
  <Fragment key="sum">
    <span className="n">3</span>
    <span className="step-t">After the call</span>
    <span className="s">Key points, decisions and action items.</span>
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
          ['Others · 0:03', 'Can we move the handover to Thursday?', ''],
          ['Me · 0:09', 'Yes. I’ll send the checklist tomorrow.', 'me'],
          ['Others · 0:15', 'Good, then I’ll invite the client.', ''],
          ['Me · 0:21', 'Thursday works. I’ll bring the invoice too.', 'me'],
        ].map(([cap, text, who], i) => (
          <div key={cap} className={`line ${who}`} style={{ '--i': i } as React.CSSProperties}>
            <small>{cap}</small>
            {text}
          </div>
        ))}
      </div>
    </Win>
    <Ind />
  </div>,
  <div
    key="sum"
    className="stage"
    role="img"
    aria-label="Illustration: the Meetings tab in shepetal. A list of calls, and the summary of the zoom.us call with an overview, a decision and two action items."
  >
    <Win title="shepetal">
      <div className="hub">
        <div className="hub-side">
          <div className="hub-row on">
            zoom.us<small>21.10.26 · 42 min</small>
          </div>
          <div className="hub-row">
            Microsoft Teams<small>20.10.26 · 18 min</small>
          </div>
          <div className="hub-row">
            zoom.us<small>17.10.26 · 9 min</small>
          </div>
        </div>
        <div className="hub-main sum">
          <div className="seg" style={{ '--i': 0 } as React.CSSProperties}>
            <span className="on">Summary</span>
            <span>Transcript</span>
          </div>
          <div style={{ '--i': 1 } as React.CSSProperties}>
            <p className="sum-h">Overview</p>
            <p>The team moved the client handover to Thursday.</p>
          </div>
          <div style={{ '--i': 2 } as React.CSSProperties}>
            <p className="sum-h">Decisions</p>
            <p>Hand over on Thursday.</p>
          </div>
          <div style={{ '--i': 3 } as React.CSSProperties}>
            <p className="sum-h">Action items</p>
            <table>
              <tbody>
                <tr>
                  <td>Me</td>
                  <td>Send the checklist</td>
                  <td>22.10.26</td>
                </tr>
                <tr>
                  <td>Luka</td>
                  <td>Invite the client</td>
                  <td>22.10.26</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </Win>
    <Ind />
  </div>,
];

/* ---------- FAQ ---------- */

const FAQ: [string, React.ReactNode][] = [
  ['Which Macs does it run on?', 'Macs with Apple silicon, on macOS 14.4 or later.'],
  [
    'How do I know it is listening?',
    <>
      The <Shush /> in the corner of your screen. A red ring while it records, orange in hands-free, blue while it writes.
    </>,
  ],
  [
    'Who knows a meeting is being recorded?',
    'You decide. Nothing records until you click Record, and automatic recording is off until you turn it on. Let people know before you record them.',
  ],
  ['How are dates written?', 'As numbers. Say “the twenty-sixth of July” and it lands as 26.07.26.'],
];

export default function Home() {
  return (
    <main className="lp">
      <Hero />

      {/* Every app */}
      <section id="apps" className="sec" aria-labelledby="apps-title">
        <div className="wrap">
          <div className="head">
            <h2 id="apps-title" className="t-h1">
              Works in every app.
            </h2>
            <p className="t-lead muted">Your editor, terminal, mail and chat.</p>
          </div>

          <div className="apps">
            <Cycle label="Apps" tabs={APP_TABS} panels={APP_SCENES} ms={7000} />
          </div>

          <div className="two">
            <div>
              <h3 className="t-h3">For builders</h3>
              <p className="t-body">Say the whole prompt. Your coding agent gets every detail you would skip when typing.</p>
            </div>
            <div>
              <h3 className="t-h3">For every day</h3>
              <p className="t-body">Replies, messages and notes in the apps you already use. Hands-free when a thought runs long.</p>
            </div>
          </div>
        </div>
      </section>

      {/* Speed */}
      <section className="sec speed-sec" aria-labelledby="speed-title">
        <div className="wrap speed">
          <h2 id="speed-title" className="t-h1">
            Instant.
          </h2>
          <p className="big-num">
            4x<span className="unit"> faster than typing.</span>
          </p>
        </div>
      </section>

      {/* Privacy and offline: the dusk band */}
      <section id="privacy" className="night grain" aria-labelledby="privacy-title">
        <div className="wrap sec privacy">
          <div className="privacy-copy">
            <h2 id="privacy-title" className="t-h1">
              100% private. Your data is yours.
            </h2>
            <p className="t-lead">Works offline.</p>
            <div className="cta-row">
              <SignInButton redirectTo="/account" className="btn btn-lg">
                {TRY}
              </SignInButton>
              <SendToMac />
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
                    <Words text="Draft the welcome email for the new client and keep it short." delay="3.4s" />
                  </p>
                </div>
              </Win>
              <Ind />
            </div>
          </InView>
        </div>
      </section>

      {/* Meetings */}
      <section id="meetings" className="sec" aria-labelledby="meet-title">
        <div className="wrap">
          <div className="head">
            <h2 id="meet-title" className="t-h1">
              Meetings, transcribed on your Mac.
            </h2>
            <p className="t-lead muted">Focus on the conversation.</p>
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
              Your recordings are in a folder on your Mac.
            </h2>
            <p className="t-lead muted">Keep them, or delete the audio after 24 hours.</p>
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
                    <span>Always record meetings automatically</span>
                    <span className="switch" />
                  </div>
                  <p className="set-note">A detected meeting records only after you click Record next to the indicator.</p>
                </div>
              </Win>
            </div>
          </InView>
        </div>
      </section>

      {/* The name, and the maker */}
      <section id="story" className="sec story-sec" aria-labelledby="name-title">
        <div className="wrap story">
          <figure className="story-photo">
            <Photo
              name="valley"
              webp
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
                You already know what you want to say before your hands catch up. I have built shepetal so one key puts what you say wherever
                your cursor is.
              </p>
              <p>It all runs on your Mac, because I wanted my own voice to stay on mine.</p>
            </div>
            <p className="sign">
              <b>Pavel Hegler</b>
              Maker of shepetal
            </p>
          </div>
        </div>
      </section>

      {/* Price */}
      <section id="price" className="sec price-sec" aria-labelledby="price-title">
        <div className="wrap">
          <div className="price">
            <h2 id="price-title" className="t-h1">
              $4.99. Yours forever.
            </h2>
            <p className="t-lead">No subscription. Every update included.</p>
            <div className="cta-row">
              <SignInButton redirectTo="/account" className="btn btn-lg">
                {TRY}
              </SignInButton>
              <SendToMac />
            </div>
          </div>
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
            Write at the speed of thought.
          </h2>
          <div className="cta-row">
            <SignInButton redirectTo="/account" className="btn btn-lg">
              {TRY}
            </SignInButton>
            <SendToMac />
          </div>
        </div>
      </section>

      <ShareBar />
    </main>
  );
}
