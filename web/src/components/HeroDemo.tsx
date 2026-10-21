'use client';

import { useEffect, useRef, useState } from 'react';
import { Ind, Win, Words, type IndState } from './landing/Mac';

// What the visitor "says", and the text that lands. A spoken date lands as numbers, as in the app.
const LINES = [
  {
    said: 'The beta goes out on Friday, and I’ll send you the release notes on the twenty-third of October.',
    text: 'The beta goes out on Friday, and I’ll send you the release notes on 23.10.26.',
  },
  { said: 'Can you check the new screenshots before lunch?', text: 'Can you check the new screenshots before lunch?' },
  { said: 'Thanks for testing it this week.', text: 'Thanks for testing it this week.' },
];

// The app's timings: a hold of 0.5 s or more is push-to-talk, a shorter tap shows the hint for 3 s.
const HOLD_MS = 500;
const HINT_MS = 3000;
const WORD_MS = 330; // a calm speaking pace
const WRITE_MS = 240; // long enough to see the blue ring; the app needs about 0.1 s
const AUTO_LINES = 2; // plays two lines on its own, then waits for the visitor

type Phase = 'rest' | 'hold' | 'talk' | 'write';
const RING: Record<Phase, IndState> = { rest: 'idle', hold: 'idle', talk: 'rec', write: 'write' };
const STATE: Record<Phase, string> = { rest: '', hold: '', talk: 'Recording', write: 'Writing' };

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
    if (phaseRef.current !== 'talk') return;
    if (heardRef.current < words()) {
      heardRef.current += 1;
      setHeard(heardRef.current);
      later(WORD_MS, speak);
    } else if (auto.current) {
      later(450, release);
    }
  };

  const press = () => {
    if (phaseRef.current !== 'rest') return;
    clear();
    setHint(false);
    heardRef.current = 0;
    setHeard(0);
    go('hold');
    later(HOLD_MS, () => {
      go('talk');
      speak();
    });
  };

  const release = () => {
    const p = phaseRef.current;
    if (p === 'hold') {
      clear();
      go('rest');
      setHint(true);
      later(HINT_MS, () => setHint(false));
    } else if (p === 'talk') {
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
    }
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
        later(900, press);
      },
      { threshold: 0.4 },
    );
    io.observe(el);
    return () => {
      io.disconnect();
      clear();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const down = phase === 'hold' || phase === 'talk';
  const speaking = phase === 'talk' || phase === 'write';
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
        <Win title="Beta on Friday" className="mail-win">
          <div className="field">
            <span>To:</span>
            <span>Maja Novak</span>
          </div>
          <div className="field">
            <span>Subject:</span>
            <span>Beta on Friday</span>
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
            aria-label="fn key. Press and hold to try dictation, then let go"
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
              <span className="said-text">
                “
                {said.slice(0, heard).map((w, i) => (
                  <span key={`${line}-${i}`} className="said-word">
                    {w}{' '}
                  </span>
                ))}
                ”
              </span>
            </>
          ) : (
            <span className="said-hint">Press and hold fn to try it, then let go.</span>
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
