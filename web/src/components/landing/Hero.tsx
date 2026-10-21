import { Fragment } from 'react';
import { SignInButton } from '@/components/SignInButton';
import { FADE, HERO_JS, HOLD, plan, SCENES } from './hero-timeline';
import { Icons, Shush, Win } from './Mac';
import { SendToMac } from './ShareBar';

export const TRY = 'Try 30 days free';

/** A line as word spans, so the inline script can move each word on its own. */
function WordSpans({ text }: { text: string }) {
  return text.split(' ').map((w, i) => (
    <Fragment key={i}>
      {i > 0 && ' '}
      <span>{w}</span>
    </Fragment>
  ));
}

/** Where the words land: a caret at the insertion point, the line (pasted whole), and the caret after it. */
function Typed({ text }: { text: string }) {
  return (
    <span className="hd-text">
      <i className="hd-caret" />
      <span className="hd-words">{text}</span>
      <i className="hd-caret" />
    </span>
  );
}

const [MAIL, CHAT, TERM] = SCENES.map((s) => s.said);

/**
 * The demo stage: a Mac screen at dusk where one key writes a spoken line into a mail, a chat and a terminal.
 * The server renders the finished email (what reduced motion and no JavaScript show); the inline script
 * after it sets the rest frame before the first paint and plays the pass on a loop (hero-timeline.ts).
 */
function Stage() {
  return (
    <figure className="hero-demo">
      <div id="hero-stage" className="hero-stage" aria-hidden="true">
        <div className="hd-menu">
          <span className="hd-menu-apps">
            <span>File</span>
            <span>Edit</span>
            <span>View</span>
          </span>
          <span className="hd-menu-status">
            {Icons.wifiOff}
            <Shush size={14} />
            <span>Fri 9:41</span>
          </span>
        </div>

        <Win title="Trip to Bled" className="hd-win hd-mail">
          <div className="hd-row">
            <span>To:</span>
            <span className="hd-chip">Maja Novak</span>
          </div>
          <div className="hd-body">
            <p>Hi Maja,</p>
            <p>
              <Typed text={MAIL} />
            </p>
          </div>
        </Win>

        <Win title="# cabin-trip" className="hd-win hd-chat">
          <div className="hd-thread">
            {[
              ['LK', 'Luka', '9:38', 'We’re at the café, table by the window.'],
              ['MN', 'Maja', '9:40', 'Ordered you a coffee.'],
            ].map(([av, who, at, text]) => (
              <div key={who} className="hd-msg">
                <span className="hd-av">{av}</span>
                <p>
                  <b>{who}</b> <small>{at}</small>
                  <br />
                  {text}
                </p>
              </div>
            ))}
          </div>
          <div className="hd-composer">
            <Typed text={CHAT} />
          </div>
        </Win>

        <Win title="~/shop" className="hd-win hd-term">
          <div className="hd-body">
            <p className="hd-dim">~/shop on main</p>
            <p className="hd-dim">Describe the change.</p>
            <p>
              <span className="hd-ps">›</span> <Typed text={TERM} />
            </p>
          </div>
        </Win>

        <div className="hd-said">
          <span className="hd-key">
            fn
            <i />
          </span>
          <span className="hd-lines">
            {SCENES.map((s) => (
              <span key={s.app} className="hd-line">
                <WordSpans text={`“${s.said}”`} />
              </span>
            ))}
          </span>
        </div>

        <span className="hd-ind">
          <i className="hd-ring hd-rec" />
          <i className="hd-ring hd-write" />
          <Shush size={32} />
        </span>
        <span className="hd-pill">
          <span className="hd-pill-rec">Recording</span>
          <span className="hd-pill-write">Writing</span>
        </span>
      </div>
      <button type="button" className="hero-pause" aria-label="Pause the demo" />
      <figcaption className="sr">shepetal writing spoken sentences into an email, a chat and a terminal.</figcaption>
      <script dangerouslySetInnerHTML={{ __html: `(${HERO_JS})(${JSON.stringify(plan())},${JSON.stringify({ hold: HOLD, fade: FADE })})` }} />
    </figure>
  );
}

/** The hero: one claim, one button, and the demo above the fold. The copy never moves. */
export function Hero() {
  return (
    <section className="hero grain" aria-labelledby="hero-title">
      <div className="wrap hero-copy">
        <h1 id="hero-title" className="hero-title">
          Press one key.
        </h1>
        <p className="hero-sub">Your words appear wherever you speak.</p>
        <p className="hero-proof">Instant. Works offline. 100% private.</p>
        <div className="cta-row hero-cta" id="hero-cta">
          <SignInButton redirectTo="/account" className="btn">
            {TRY}
          </SignInButton>
          <SendToMac />
        </div>
        <p className="hero-quiet">
          For Mac. <span className="hero-phone">30 days free. </span>$4.99. Yours forever.
        </p>
      </div>
      <Stage />
    </section>
  );
}
