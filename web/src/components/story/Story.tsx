import { Fragment } from 'react';
import { FLOWS, HERO_WORDS, TYPED_WORDS, flowWords, type FlowId } from './choreography';
import { KeySvg } from './KeySvg';
import { StoryMotion } from './StoryMotion';
import './story.css';
import './story.generated.css';

/** The Noto 🤫 (BRAND.md): drawn from the file, since a typed 🤫 shows Apple's artwork on a Mac. */
export const SHUSH = '/brand/emoji/emoji_u1f92b.svg';
export const TRY = 'Try 30 days free';

/** A sentence written word by word in its window, with the caret that leads it (choreography.ts, FLOWS). */
function Flow({ id }: { id: FlowId }) {
  const words = flowWords(id);
  return (
    <>
      <span className={`kc-car kc-${id}-s`} />
      {words.map((w, j) => (
        <Fragment key={j}>
          <span className={`kc-fw kc-${id}-${j}`}>{w}</span>
          {j < words.length - 1 ? ' ' : null}
        </Fragment>
      ))}
    </>
  );
}

/** The trial button: the install guide, which starts the download. Open, no sign-in (that happens in the app). */
function TryButton({ className = '' }: { className?: string }) {
  return (
    <a className={`kc-cta ${className}`.trim()} href="/install">
      <svg className="kc-cta-mac" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
        <path d="M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 3.792 3.039 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 1.637-.026 2.676-1.48 3.676-2.948 1.156-1.688 1.636-3.325 1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 2.597-4.559-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.09-4.61 1.09zM15.53 3.83c.843-1.012 1.4-2.427 1.245-3.83-1.207.052-2.662.805-3.532 1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.559-1.701" />
      </svg>
      {TRY}
    </a>
  );
}

/** 0 · The key: it presses on scroll and is held while the line is written, then docks in the corner. */
function Hero() {
  return (
    <section className="kc-track kc-t0" aria-labelledby="kc-h0">
      <div className="kc-stage">
        <header className="kc-head">
          <a className="kc-mark" href="/">
            shepetal
          </a>
        </header>

        <div className="kc-grid">
          <h1 id="kc-h0" className="kc-h1">
            Press one key.
          </h1>

          <div className="kc-stagekey">
            <button className="kc-key" type="button" aria-label="Press the fn key">
              <KeySvg p="kc" />
            </button>
          </div>

          <p className="kc-lede">
            {HERO_WORDS.map((w, i) => (
              <Fragment key={w}>
                <span className={`kc-w kc-w${i}`}>
                  <span className="kc-wx">
                    <span className="kc-wy">
                      <span className="kc-wi">{w}</span>
                      {/* the orange copy that fades as the word lands: drawn by CSS, so the page text has each word once */}
                      <span className="kc-wo" aria-hidden="true" data-w={w} />
                    </span>
                  </span>
                </span>
                {i < HERO_WORDS.length - 1 ? ' ' : null}
              </Fragment>
            ))}
          </p>

          <div className="kc-ctarow">
            <TryButton />
          </div>
        </div>

        <div className="kc-cue kc-mono" aria-hidden="true">
          <span className="kc-cue-line" />
          <span>Scroll</span>
        </div>
      </div>
    </section>
  );
}

/** The corner: the 🤫 recording mark and the docked key, held during every writing window. */
function Corner() {
  return (
    <div className="kc-corner" aria-hidden="true">
      <div className="kc-shf">
        <img src={SHUSH} alt="" width={28} height={28} />
      </div>
      <div className="kc-dock">
        <div className="kc-dock-out">
          <div className="kc-dock-on">
            <div className="kc-dock-in">
              <KeySvg p="kd" />
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

/** A pinned chapter: the sticky stage and its two-column grid. */
function Chapter({
  track,
  label,
  children,
}: {
  track: 't1' | 't2' | 't3' | 't4';
  label: string;
  children: React.ReactNode;
}) {
  return (
    <section className={`kc-track kc-${track}`} aria-labelledby={label}>
      <div className="kc-stage kc-chs">
        <div className="kc-cg">{children}</div>
      </div>
    </section>
  );
}

const FIELDS: { app: string; id: FlowId; kind: 'mail' | 'chat' | 'code' | 'terminal' | 'doc' }[] = [
  { app: 'Mail', id: 'f0', kind: 'mail' },
  { app: 'Chat', id: 'f1', kind: 'chat' },
  { app: 'Code', id: 'f2', kind: 'code' },
  { app: 'Terminal', id: 'f3', kind: 'terminal' },
  { app: 'Doc', id: 'f4', kind: 'doc' },
];

const FIELD_CLASS = {
  mail: 'kc-say',
  chat: 'kc-say kc-say-chat',
  code: 'kc-say-code',
  terminal: 'kc-say-code',
  doc: 'kc-say-doc',
};
const FIELD_PREFIX = { mail: '', chat: '', code: '// ', terminal: '$ git commit -m "', doc: '' };

/** 1 · Every app: five fields, each with its own sentence. */
function EveryApp() {
  return (
    <Chapter track="t1" label="kc-h1">
      <h2 id="kc-h1" className="kc-h2">
        Works in every app.
      </h2>
      <div className="kc-rows">
        {FIELDS.map(({ app, id, kind }) => (
          <div key={id} className="kc-row">
            <span className="kc-mono">{app}</span>
            <p className={FIELD_CLASS[kind]}>
              {FIELD_PREFIX[kind] && <span className="kc-say-pre">{FIELD_PREFIX[kind]}</span>}
              <Flow id={id} />
            </p>
          </div>
        ))}
      </div>
    </Chapter>
  );
}

/** 2 · Speed: the spoken lane against the typed lane. */
function Speed() {
  return (
    <Chapter track="t2" label="kc-h2">
      <h2 id="kc-h2" className="kc-h2">
        Instant.<span className="kc-h2-sub">4x faster than typing.</span>
      </h2>
      <div className="kc-rows">
        <div className="kc-row kc-row-lg">
          <span className="kc-mono kc-lane-label">
            Spoken <span className="kc-sp-led" />
          </span>
          <p className="kc-lane">
            <span className="kc-car kc-c2s" />
            <span className="kc-sp-text">I’ll send the revised contract before lunch tomorrow.</span>
            <span className="kc-car kc-c2e" />
          </p>
        </div>
        <div className="kc-row kc-row-lg">
          <span className="kc-mono">Typed</span>
          <p className="kc-lane kc-lane-typed">
            <span className="kc-car kc-car-ink kc-c2t" />
            {TYPED_WORDS.map((w, j) => (
              <Fragment key={j}>
                <span className={`kc-tw kc-ty${j}`}>{w}</span>
                {j < TYPED_WORDS.length - 1 ? ' ' : null}
              </Fragment>
            ))}
          </p>
        </div>
      </div>
    </Chapter>
  );
}

/** 3 · Private: the network line is cut, "Offline" appears, and only then does the note flow in. */
function Private() {
  return (
    <Chapter track="t3" label="kc-h3">
      <div>
        <h2 id="kc-h3" className="kc-h2">
          100% private. Your data is yours.
        </h2>
        <p className="kc-sub">Works offline.</p>
      </div>
      <div className="kc-net">
        <div className="kc-box">
          <span className="kc-mono kc-box-label">Your Mac</span>
          <p className="kc-note">
            <Flow id="b3" />
          </p>
        </div>
        <div className="kc-wire">
          <span className="kc-net-a" />
          <span className="kc-net-b" />
          <span className="kc-net-l kc-mono">Network</span>
          <span className="kc-off kc-mono">Offline</span>
        </div>
      </div>
    </Chapter>
  );
}

const TRANSCRIPT: { who: string; id: FlowId }[] = [
  { who: 'Ana', id: 't0' },
  { who: 'You', id: 't1' },
  { who: 'Ana', id: 't2' },
];

/** 4 · Meetings: the meeting reminder, Record, and three transcript lines. */
function Meetings() {
  return (
    <Chapter track="t4" label="kc-h4">
      <h2 id="kc-h4" className="kc-h2">
        Meetings, transcribed on your Mac.
      </h2>
      <div>
        <div className="kc-rem">
          <div>
            <span className="kc-mono">Meeting reminder</span>
            <p className="kc-rem-title">Call with Ana is starting.</p>
          </div>
          <span className="kc-recbtn" aria-hidden="true">
            <span className="kc-recbase" />
            <span className="kc-recface">
              <span className="kc-rec-a">Record</span>
              <span className="kc-rec-b">Recording</span>
            </span>
          </span>
        </div>
        <div className="kc-script">
          {TRANSCRIPT.map(({ who, id }, k) => (
            <p key={id} className="kc-line">
              <span className={`kc-mono kc-sl${k}`}>{who}</span>
              <span className="kc-line-text">
                <Flow id={id} />
              </span>
            </p>
          ))}
        </div>
      </div>
    </Chapter>
  );
}

/** 5 · The name. */
function TheName() {
  return (
    <section className="kc-track kc-t5" aria-labelledby="kc-h5">
      <div className="kc-stage kc-name">
        <img className="kc-n0" src={SHUSH} alt="" width={52} height={52} />
        <h2 id="kc-h5" className="kc-name-h">
          <span className="kc-n1" lang="sl">
            šepetal
          </span>{' '}
          <span className="kc-n2">(Slovene): he whispered.</span>
        </h2>
      </div>
    </section>
  );
}

/** 6 · Try it: 30 days free, the button, the two plans, and the footer. */
function TryIt() {
  return (
    <section id="try" className="kc-try" aria-labelledby="kc-h6">
      <div className="kc-cg kc-cg-try">
        <div>
          <h2 id="kc-h6" className="kc-h2 kc-h2-try">
            30 days free.
          </h2>
          <TryButton className="kc-cta-try" />
        </div>
        <div className="kc-plans">
          <div className="kc-plan">
            <p className="kc-price">$23.99</p>
            <p className="kc-price-line">once. Yours forever.</p>
          </div>
          <div className="kc-plan">
            <p className="kc-price">$0.99</p>
            <p className="kc-price-line">a month.</p>
          </div>
        </div>
      </div>
      <footer className="kc-foot">
        <a className="kc-mark kc-mark-sm" href="/">
          shepetal
        </a>
        <nav aria-label="Legal" className="kc-mono kc-foot-nav">
          <a href="/privacy">Privacy</a>
          <a href="/terms">Terms</a>
          <a href="/refunds">Refunds</a>
          <a href="/legal">Legal</a>
        </nav>
      </footer>
    </section>
  );
}

/** The landing page: the approved full scroll story, chapter by chapter. */
export function Story() {
  return (
    <main className="kc">
      <Hero />
      <Corner />
      <EveryApp />
      <Speed />
      <Private />
      <Meetings />
      <TheName />
      <TryIt />
      <StoryMotion />
    </main>
  );
}

/** Every sentence the story writes, for the tests: the claims must be in the page as real text. */
export const STORY_SENTENCES = Object.values(FLOWS).map((f) => f.text);
