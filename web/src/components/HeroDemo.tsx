'use client';

import { useEffect, useRef, useState } from 'react';

// What the demo "hears". Each press pastes the next one, like the app does.
const SENTENCES = [
  'Running ten minutes late, start without me.',
  'Can you send me the slides from Tuesday?',
  'Pick up oat milk and the good coffee on the way home.',
  'Ship it on Friday if the tests pass.',
];

// The app's own timings: a hold under 0.5 s is a tap and shows the hint for 2 s.
const HOLD_MS = 500;
const PROCESS_MS = 450;
const HINT_MS = 2000;

type Phase = 'rest' | 'hold' | 'talk' | 'process';

const WORDS = ['hold fn,', 'talk,', 'done.'];
// How many headline words are lit in each phase. At rest the whole line is lit.
const LIT: Record<Phase, number> = { rest: 3, hold: 1, talk: 2, process: 2 };

export function HeroDemo() {
  const [phase, setPhase] = useState<Phase>('rest');
  const [text, setText] = useState('');
  const [hint, setHint] = useState(false);
  const count = useRef(0);
  const timers = useRef<ReturnType<typeof setTimeout>[]>([]);
  const phaseRef = useRef<Phase>('rest');

  const go = (p: Phase) => {
    phaseRef.current = p;
    setPhase(p);
  };
  const later = (ms: number, fn: () => void) => timers.current.push(setTimeout(fn, ms));
  const clear = () => {
    timers.current.forEach(clearTimeout);
    timers.current = [];
  };

  const press = () => {
    if (phaseRef.current !== 'rest') return;
    clear();
    setHint(false);
    go('hold');
    later(HOLD_MS, () => go('talk'));
  };

  const release = () => {
    const p = phaseRef.current;
    if (p === 'hold') {
      clear();
      go('rest');
      setHint(true);
      later(HINT_MS, () => setHint(false));
    } else if (p === 'talk') {
      go('process');
      later(PROCESS_MS, () => {
        const next = SENTENCES[count.current++ % SENTENCES.length];
        setText((t) => (t ? `${t} ${next}` : next));
        go('rest');
      });
    }
  };

  // One run on load, unless the visitor asked for less motion.
  useEffect(() => {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      setText(SENTENCES[count.current++]);
      return;
    }
    const t1 = setTimeout(press, 700);
    const t2 = setTimeout(release, 2500);
    return () => {
      clearTimeout(t1);
      clearTimeout(t2);
      clear();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const down = phase === 'hold' || phase === 'talk';
  const mode = phase === 'talk' ? 'rec' : phase === 'process' ? 'busy' : 'idle';

  return (
    <>
      <h1 className="display text-[clamp(4rem,13vw,10.5rem)] leading-[0.88]">
        {WORDS.map((w, i) => (
          <span key={w} className="hero-word block" data-dim={i >= LIT[phase]}>
            {w}
          </span>
        ))}
      </h1>

      <p
        className="mt-10 min-h-[4.5rem] max-w-[32ch] text-[clamp(1.35rem,2.6vw,1.9rem)] leading-snug"
        aria-live="polite"
      >
        {text}
        <span className="caret" aria-hidden="true" />
      </p>

      <div className="mt-8 flex items-end gap-2" role="group" aria-label="Bottom-left keys of a Mac keyboard">
        <button
          type="button"
          className="key key-fn"
          aria-pressed={down}
          aria-label="fn key. Press and hold to try dictation"
          onPointerDown={(e) => {
            press();
            e.currentTarget.setPointerCapture(e.pointerId); // the release still lands if the pointer slides off
          }}
          onPointerUp={release}
          onPointerCancel={release}
          onKeyDown={(e) => {
            if ((e.key === ' ' || e.key === 'Enter') && !e.repeat) {
              e.preventDefault();
              press();
            }
          }}
          onKeyUp={(e) => {
            if (e.key === ' ' || e.key === 'Enter') release();
          }}
          onContextMenu={(e) => e.preventDefault()}
        >
          <span className="self-end">fn</span>
          <Globe />
        </button>
        <span className="key key-ghost" aria-hidden="true">
          <span className="self-end">⌃</span>
          <span>control</span>
        </span>
        <span className="key key-ghost" aria-hidden="true">
          <span className="self-end">⌥</span>
          <span>option</span>
        </span>
        <p className="ml-3 pb-1 text-sm text-[var(--hush)]">Press and hold fn to try it</p>
      </div>

      <div className="shush" data-mode={mode} aria-hidden="true">
        <span className="shush-face">🤫</span>
        {hint && <span className="shush-hint">Hold fn to talk</span>}
      </div>
    </>
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
