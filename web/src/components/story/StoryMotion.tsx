'use client';

import { useEffect } from 'react';

/** Reduced motion shows every chapter in its final state: no measuring, no scrubbing, the key does nothing. */
const STILL = '(prefers-reduced-motion: reduce)';

/**
 * The story's only script (the design's component logic). It renders nothing and works on the server-rendered markup:
 * - measure: each hero word flies from the key face to its own place (on a phone the flight is short and comes from
 *   above), and the docked key starts exactly over the hero key, so it can fly into the corner;
 * - sync, for browsers without scroll timelines: one variable, --p, per pinned chapter (and --pN / --eN on the root);
 * - the key is a button: it plays the hero by scrolling through it, or rewinds when it is done.
 * It writes CSS variables only, so the layout never changes.
 */
export function StoryMotion() {
  useEffect(() => {
    const root = document.querySelector<HTMLElement>('.kc');
    if (!root) return;
    const native = typeof CSS !== 'undefined' && !!CSS.supports && CSS.supports('animation-timeline: view()');
    const still = window.matchMedia(STILL);
    let rafR = 0;
    let rafS = 0;

    const sync = () => {
      if (native || still.matches) return;
      const tracks = root.querySelectorAll<HTMLElement>('.kc-track');
      const H = window.innerHeight;
      tracks.forEach((track, i) => {
        const r = track.getBoundingClientRect();
        const span = r.height - H;
        const p = (span > 0 ? Math.min(1, Math.max(0, -r.top / span)) : 0).toFixed(4);
        const e = Math.min(1, Math.max(0, (H - r.top) / H)).toFixed(4);
        track.style.setProperty('--p', p);
        root.style.setProperty('--p' + i, p);
        root.style.setProperty('--e' + i, e);
      });
    };

    const measure = () => {
      const emit = root.querySelector('.kc-k-emit');
      const words = root.querySelectorAll<HTMLElement>('.kc-w');
      if (!emit || !words.length) return;
      const e = emit.getBoundingClientRect();
      const ex = e.left + e.width / 2;
      const ey = e.top + e.height / 2;
      const phone = window.innerWidth <= 760;
      words.forEach((word) => {
        const r = word.getBoundingClientRect();
        let dx = ex - (r.left + r.width / 2);
        let dy = ey - (r.top + r.height / 2);
        if (phone) {
          const d = Math.hypot(dx, dy) || 1;
          const k = Math.min(1, (r.height * 1.4) / d);
          dx *= k;
          dy *= k;
        }
        word.style.setProperty('--dx', dx.toFixed(1) + 'px');
        word.style.setProperty('--dy', dy.toFixed(1) + 'px');
      });
      const key = root.querySelector('.kc-key');
      const stage = root.querySelector('.kc-t0 .kc-stage');
      const box = root.querySelector('.kc-dock');
      const dockIn = root.querySelector<HTMLElement>('.kc-dock-in');
      if (key && stage && box && dockIn) {
        const K = key.getBoundingClientRect();
        const S = stage.getBoundingClientRect();
        const D = box.getBoundingClientRect();
        if (D.width) {
          dockIn.style.setProperty('--kx', (K.left - D.left).toFixed(1) + 'px');
          dockIn.style.setProperty('--ky', (K.top - S.top - D.top).toFixed(1) + 'px');
          dockIn.style.setProperty('--ks', (K.width / D.width).toFixed(4));
        }
      }
    };

    const press = () => {
      const t = root.querySelector('.kc-t0');
      if (!t || still.matches) return;
      const r = t.getBoundingClientRect();
      const span = r.height - window.innerHeight;
      const top = window.scrollY + r.top;
      if (span <= 0) return;
      const p = -r.top / span;
      window.scrollTo({ top: p < 0.75 ? top + span * 0.79 : top, behavior: 'smooth' });
    };

    const onResize = () => {
      cancelAnimationFrame(rafR);
      rafR = requestAnimationFrame(() => {
        measure();
        sync();
      });
    };
    const onScroll = () => {
      cancelAnimationFrame(rafS);
      rafS = requestAnimationFrame(sync);
    };

    const key = root.querySelector('.kc-key');
    key?.addEventListener('click', press);
    window.addEventListener('resize', onResize);
    if (!native) window.addEventListener('scroll', onScroll, { passive: true });
    measure();
    document.fonts?.ready.then(measure);
    sync();
    return () => {
      key?.removeEventListener('click', press);
      window.removeEventListener('resize', onResize);
      window.removeEventListener('scroll', onScroll);
      cancelAnimationFrame(rafR);
      cancelAnimationFrame(rafS);
    };
  }, []);
  return null;
}
