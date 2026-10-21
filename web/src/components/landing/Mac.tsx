import type { CSSProperties, ReactNode } from 'react';

const NOTO = '/brand/emoji/emoji_u1f92b.svg';

/** The 🤫 from the Noto file, inline with text. A typed 🤫 would show Apple's artwork on a Mac (BRAND.md). */
export function Shush({ size }: { size?: number }) {
  return <img className="shush-i" src={NOTO} alt="🤫" width={size ?? 16} height={size ?? 16} decoding="async" />;
}

/**
 * Text that lands the way dictated text does: word by word, 4 px blur to sharp, 2 px rise.
 * The stagger shrinks with the length so the whole line is done within 560 ms (identity.md, motion).
 */
export function Words({ text, delay }: { text: string; delay?: string }) {
  const all = text.split(' ');
  const step = all.length > 1 ? Math.min(40, Math.floor(320 / (all.length - 1))) : 0;
  return all.map((w, i) => (
    <span key={i}>
      <span className="w" style={{ '--t': `${i * step}ms`, ...(delay ? { '--d': delay } : {}) } as CSSProperties}>
        {w}
      </span>
      {i < all.length - 1 ? ' ' : null}
    </span>
  ));
}

/** A Mac window with grey (inactive) traffic lights, so no state color appears in the chrome. */
export function Win({ title, bar, className = '', children }: { title?: string; bar?: ReactNode; className?: string; children: ReactNode }) {
  return (
    <div className={`win ${className}`}>
      <div className="win-bar">
        <span className="lights">
          <i />
          <i />
          <i />
        </span>
        {bar ?? <span className="win-title">{title}</span>}
      </div>
      {children}
    </div>
  );
}

export type IndState = 'idle' | 'rec' | 'free' | 'write';

/** The app's indicator: the 🤫 in an 18 px circle with a 2 px state ring inside it, 8 px in from the corner. */
export function Ind({ state = 'idle', hint, className = '' }: { state?: IndState; hint?: ReactNode; className?: string }) {
  return (
    <span className={`ind ${className}`} data-state={state}>
      <span className="ind-face">
        <img src={NOTO} alt="" width={13} height={13} decoding="async" />
      </span>
      {hint}
    </span>
  );
}

const icon = (d: ReactNode) => (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    {d}
  </svg>
);

/** Lucide-style line icons: 24 px grid, 1.5 px stroke, round caps (identity.md, iconography). */
export const Icons = {
  mail: icon(
    <>
      <rect x="3" y="5" width="18" height="14" rx="2" />
      <path d="m3.5 6.5 8.5 6.5 8.5-6.5" />
    </>,
  ),
  chat: icon(<path d="M4 5.5A1.5 1.5 0 0 1 5.5 4h13A1.5 1.5 0 0 1 20 5.5v9a1.5 1.5 0 0 1-1.5 1.5H9l-5 4z" />),
  code: icon(<path d="m9 7-5 5 5 5M15 7l5 5-5 5" />),
  term: icon(
    <>
      <rect x="3" y="4" width="18" height="16" rx="2" />
      <path d="m7 9 3 3-3 3M12.5 15H17" />
    </>,
  ),
  doc: icon(
    <>
      <path d="M6 3h8l4 4v14H6z" />
      <path d="M14 3v4h4M9 12h6M9 16h6" />
    </>,
  ),
  wifi: icon(
    <>
      <path d="M2.5 9a14 14 0 0 1 19 0M5.5 12.5a9.5 9.5 0 0 1 13 0M8.8 15.8a4.8 4.8 0 0 1 6.4 0" />
      <circle cx="12" cy="19" r="0.6" fill="currentColor" />
    </>,
  ),
  wifiOff: icon(
    <>
      <path d="M12 20h.01M8.5 16.4a5 5 0 0 1 7 0M5 12.9a10 10 0 0 1 5.2-2.7M19 12.9a10 10 0 0 0-2-1.5M2 8.8a15 15 0 0 1 4.2-2.6M22 8.8A15 15 0 0 0 10.7 5" />
      <path d="m2 2 20 20" />
    </>,
  ),
  plane: icon(<path d="M10.2 20.5 12 17l1.8 3.5M12 17V9.5M12 9.5 3 14v-2l9-6.5M12 9.5l9 4.5v-2l-9-6.5M12 3v2.5" />),
  moon: icon(<path d="M19 14.5A7.5 7.5 0 0 1 9.5 5a7.5 7.5 0 1 0 9.5 9.5z" />),
};
