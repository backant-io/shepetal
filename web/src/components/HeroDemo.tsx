'use client';

import { useEffect, useRef, useState } from 'react';
import { Ind, Win, Words, type IndState } from './landing/Mac';

// What the visitor "says", and the text that lands. A spoken date lands as numbers, as in the app.
const LINES = [
  {
    said: 'I’ll book the cabin for the twenty-third of October.',
    text: 'I’ll book the cabin for 23.10.26.',
  },
  { said: 'Can you send me the address before the weekend?', text: 'Can you send me the address before the weekend?' },
  { said: 'Thanks for planning all of it.', text: 'Thanks for planning all of it.' },
];

// The app's gesture (FnGesture.swift): recording starts as fn goes down. Let go after 0.5 s or more and the
// text is written. A shorter press waits 0.5 s for a second press, which locks hands-free; with no second
// press nothing is written and the hint shows for 3 s. In hands-free, the next press writes the text.
const HOLD_MS = 500;
const DOUBLE_MS = 500;
const HINT_MS = 3000;
const FIRST_WORD_MS = 280; // the visitor starts speaking a moment after the key goes down
const WORD_MS = 330; // a calm speaking pace
const WRITE_MS = 240; // long enough to see the blue ring; the app needs about 0.1 s
const AUTO_LINES = 2; // plays two lines on its own, then waits for the visitor

export type Phase = 'rest' | 'talk' | 'wait' | 'free' | 'write';

/** The next phase after fn goes down, comes up after `heldMs`, or the double-tap window runs out ('settle'). */
export function gesture(p: Phase, e: 'down' | 'up' | 'settle', heldMs = 0): Phase {
  if (e === 'down') return p === 'rest' ? 'talk' : p === 'wait' ? 'free' : p === 'free' ? 'write' : p;
  if (e === 'up') return p !== 'talk' ? p : heldMs >= HOLD_MS ? 'write' : 'wait';
  return p === 'wait' ? 'rest' : p;
}
const RING: Record<Phase, IndState> = { rest: 'idle', talk: 'rec', wait: 'rec', free: 'free', write: 'write' };
const STATE: Record<Phase, string> = { rest: '', talk: 'Recording', wait: 'Recording', free: 'Hands-free', write: 'Writing' };
const LISTENING: Phase[] = ['talk', 'wait', 'free'];

export function HeroDemo({ wallpaper }: { wallpaper: React.ReactNode }) {
  const [phase, setPhase] = useState<Phase>('rest');
  const [heard, setHeard] = useState(0); // words of the current line said so far
  const [line, setLine] = useState(0);
  const [landed, setLanded] = useState<{ key: number; text: string }[]>([]);
  const [hint, setHint] = useState(false);
  const phaseRef = useRef<Phase>('rest');
  const heardRef = useRef(0);
  const lineRef = useRef(0);
  const auto = useRef(false);
  const downAt = useRef(0);
  const waitTimer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const timers = useRef<ReturnType<typeof setTimeout>[]>([]);
  const root = useRef<HTMLDivElement>(null);

  const go = (p: Phase) => {
    phaseRef.current = p;
    setPhase(p);
  };
  const later = (ms: number, fn: () => void) => timers.current.push(setTimeout(fn, ms));
  const clear = () => {
    timers.current.forEach(clearTimeout);
    timers.current = [];
  };
  const words = () => LINES[lineRef.current % LINES.length].said.split(' ').length;

  const speak = () => {
    if (!LISTENING.includes(phaseRef.current)) return;
    if (heardRef.current < words()) {
      heardRef.current += 1;
      setHeard(heardRef.current);
      later(WORD_MS, speak);
    } else if (auto.current) {
      later(450, release);
    }
  };

  const press = () => {
    const next = gesture(phaseRef.current, 'down');
    if (next === 'free') {
      clearTimeout(waitTimer.current); // the second press: hands-free, and the words keep coming
      return go('free');
    }
    if (next === 'write') return write();
    if (next !== 'talk') return;
    clear();
    setHint(false);
    heardRef.current = 0;
    setHeard(0);
    downAt.current = Date.now();
    go('talk');
    later(FIRST_WORD_MS, speak);
  };

  const release = () => {
    const next = gesture(phaseRef.current, 'up', Date.now() - downAt.current);
    if (next === 'write') return write();
    if (next !== 'wait') return;
    go('wait');
    waitTimer.current = setTimeout(() => {
      // Too short, and no second press: nothing is written, the hint shows.
      clear();
      go(gesture('wait', 'settle'));
      setHint(true);
      later(HINT_MS, () => setHint(false));
    }, DOUBLE_MS);
    timers.current.push(waitTimer.current);
  };

  const write = () => {
    clear();
    if (heardRef.current === 0) return go('rest');
    go('write');
    later(WRITE_MS, () => {
      const n = lineRef.current;
      const text = LINES[n % LINES.length].text;
      setLanded((l) => (l.length >= 3 ? [{ key: n, text }] : [...l, { key: n, text }]));
      lineRef.current = n + 1;
      setLine(n + 1);
      go('rest');
      if (auto.current && n + 1 < AUTO_LINES) later(2600, press);
      else auto.current = false;
    });
  };

  // Plays when the screen comes into view. With reduced motion it shows the result instead.
  useEffect(() => {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      setLanded([{ key: 0, text: LINES[0].text }]);
      lineRef.current = 1;
      setLine(1);
      return;
    }
    const el = root.current;
    if (!el) return;
    const io = new IntersectionObserver(
      ([e]) => {
        if (!e.isIntersecting) return;
        io.disconnect();
        auto.current = true;
        later(600, press);
      },
      // Low, so it plays in the first viewport: on a laptop or a phone only about a third of the screen shows there.
      { threshold: 0.15 },
    );
    io.observe(el);
    return () => {
      io.disconnect();
      clear();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const down = phase === 'talk';
  const speaking = phase !== 'rest';
  const said = LINES[line % LINES.length].said.split(' ');

  return (
    <div ref={root} className="demo">
      <div
        className="screen"
        role="img"
        aria-label="Illustration: a Mac with a new email open. While fn is held, the 🤫 in the bottom-left corner of the screen shows a red ring. On release it pulses blue and the spoken words land in the email, with the spoken date written as 23.10.26."
      >
        {wallpaper}
        <div className="menubar" aria-hidden="true">
          <b>Mail</b>
          <span className="mb-hide">File</span>
          <span className="mb-hide">Edit</span>
          <span className="mb-hide">View</span>
          <span className="mb-end">
            <img className="mb-shush" src="/brand/emoji/emoji_u1f92b.svg" alt="" width={14} height={14} />
            <span>Wed 09:41</span>
          </span>
        </div>
        <Win title="Trip to Bled" className="mail-win">
          <div className="field">
            <span>To:</span>
            <span>Maja Novak</span>
          </div>
          <div className="field">
            <span>Subject:</span>
            <span>Trip to Bled</span>
          </div>
          <div className="mail-body">
            <p>Hi Maja,</p>
            {landed.map((l, i) => (
              <p key={l.key}>
                <Words text={l.text} />
                {i === landed.length - 1 && <span className="caret" />}
              </p>
            ))}
            {landed.length === 0 && (
              <p>
                <span className="caret" />
              </p>
            )}
          </div>
        </Win>
        <Ind state={RING[phase]} hint={hint ? <span className="ind-hint">Hold fn to talk · double-tap for hands-free</span> : null} />
        <span className="illus">Illustration</span>
      </div>

      <div className="keys">
        <div className="keycaps" role="group" aria-label="The bottom-left keys of a Mac keyboard">
          <button
            type="button"
            className="key key-fn"
            aria-pressed={down}
            aria-label="fn key. Hold it to try dictation, or double-tap it for hands-free"
            onPointerDown={(e) => {
              auto.current = false;
              press();
              e.currentTarget.setPointerCapture(e.pointerId); // the release still lands if the pointer slides off
            }}
            onPointerUp={release}
            onPointerCancel={release}
            onKeyDown={(e) => {
              if ((e.key === ' ' || e.key === 'Enter') && !e.repeat) {
                e.preventDefault();
                auto.current = false;
                press();
              }
            }}
            onKeyUp={(e) => {
              if (e.key === ' ' || e.key === 'Enter') release();
            }}
            onContextMenu={(e) => e.preventDefault()}
          >
            <span className="key-top">fn</span>
            <Globe />
          </button>
          <span className="key key-ghost" aria-hidden="true">
            <span className="key-top">⌃</span>
            <span>control</span>
          </span>
          <span className="key key-ghost key-hide" aria-hidden="true">
            <span className="key-top">⌥</span>
            <span>option</span>
          </span>
        </div>
        <div className="said" aria-live="off">
          {speaking ? (
            <>
              <span className="said-state" data-state={RING[phase]}>
                <i aria-hidden="true" />
                {STATE[phase]}
              </span>
              {heard > 0 && (
                <span className="said-text">
                  “
                  {said.slice(0, heard).map((w, i) => (
                    <span key={`${line}-${i}`} className="said-word">
                      {w}{' '}
                    </span>
                  ))}
                  ”
                </span>
              )}
            </>
          ) : (
            <span className="said-hint">Hold the fn key here to try it, or double-tap it for hands-free.</span>
          )}
        </div>
      </div>
      <p className="sr" aria-live="polite">
        {landed.length ? landed[landed.length - 1].text : ''}
      </p>
    </div>
  );
}

function Globe() {
  return (
    <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3" aria-hidden="true">
      <circle cx="8" cy="8" r="6.5" />
      <path d="M1.5 8h13M8 1.5c2 2 2.8 4.2 2.8 6.5S10 12.5 8 14.5C6 12.5 5.2 10.3 5.2 8S6 3.5 8 1.5Z" />
    </svg>
  );
}
