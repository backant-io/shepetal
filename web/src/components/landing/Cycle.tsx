'use client';

import { useEffect, useId, useRef, useState, type CSSProperties, type ReactNode } from 'react';

/** Sets data-visible while the element is on screen; CSS pauses every animation inside it otherwise. */
function useVisible<T extends HTMLElement>() {
  const ref = useRef<T>(null);
  const [visible, setVisible] = useState(false);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const io = new IntersectionObserver(([e]) => setVisible(e.isIntersecting), { threshold: 0.35 });
    io.observe(el);
    return () => io.disconnect();
  }, []);
  return [ref, visible] as const;
}

export function InView({ className = '', children }: { className?: string; children: ReactNode }) {
  const [ref, visible] = useVisible<HTMLDivElement>();
  return (
    <div ref={ref} className={`inview ${className}`} data-visible={visible}>
      {children}
    </div>
  );
}

/**
 * Tabs that move to the next scene on their own while they are on screen, and stop once the
 * reader picks one or moves focus into them. Each panel is shown fresh, so its CSS animation plays from the start.
 */
export function Cycle({
  label,
  tabs,
  panels,
  ms = 6000,
  tabClass = '',
}: {
  label: string;
  tabs: ReactNode[];
  panels: ReactNode[];
  ms?: number;
  tabClass?: string;
}) {
  const id = useId();
  const [ref, visible] = useVisible<HTMLDivElement>();
  const [active, setActive] = useState(0);
  const [auto, setAuto] = useState(true);
  const [still, setStill] = useState(false);
  const buttons = useRef<(HTMLButtonElement | null)[]>([]);

  useEffect(() => setStill(window.matchMedia('(prefers-reduced-motion: reduce)').matches), []);

  const run = auto && visible && !still;
  useEffect(() => {
    if (!run) return;
    const t = setTimeout(() => setActive((n) => (n + 1) % panels.length), ms);
    return () => clearTimeout(t);
  }, [run, active, ms, panels.length]);

  const pick = (n: number, focus = false) => {
    setAuto(false);
    setActive(n);
    if (focus) buttons.current[n]?.focus();
  };

  return (
    <div
      ref={ref}
      className="cycle"
      data-visible={visible}
      data-run={run}
      style={{ '--cycle-ms': `${ms}ms` } as CSSProperties}
      // A keyboard reader inside the tabs keeps the tab they are on (WCAG 2.2.2).
      onFocus={() => setAuto(false)}
    >
      <div role="tablist" aria-label={label} className="cycle-tabs">
        {tabs.map((t, n) => (
          <button
            key={n}
            ref={(b) => {
              buttons.current[n] = b;
            }}
            type="button"
            role="tab"
            id={`${id}-t${n}`}
            aria-selected={n === active}
            aria-controls={`${id}-p${n}`}
            tabIndex={n === active ? 0 : -1}
            className={`cycle-tab ${tabClass}`}
            onClick={() => pick(n)}
            onKeyDown={(e) => {
              const k = e.key;
              if (k === 'ArrowRight' || k === 'ArrowDown') pick((n + 1) % tabs.length, true);
              else if (k === 'ArrowLeft' || k === 'ArrowUp') pick((n - 1 + tabs.length) % tabs.length, true);
              else return;
              e.preventDefault();
            }}
          >
            {t}
            <span className="cycle-bar" aria-hidden="true" />
          </button>
        ))}
      </div>
      <div>
        {panels.map((p, n) => (
          <div key={n} role="tabpanel" id={`${id}-p${n}`} aria-labelledby={`${id}-t${n}`} hidden={n !== active}>
            {p}
          </div>
        ))}
      </div>
    </div>
  );
}
