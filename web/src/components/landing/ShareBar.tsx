'use client';

import { useEffect, useState } from 'react';

/** Sends this page on: the share sheet where there is one, else the clipboard. `copied` is true for a moment after a copy. */
function useShare() {
  const [copied, setCopied] = useState(false);
  const share = async () => {
    const url = location.href.split('#')[0]; // keeps the link's own parameters (utm_*), so the Mac visit is counted
    try {
      if (navigator.share) return await navigator.share({ title: 'shepetal for Mac', url });
      await navigator.clipboard.writeText(url);
      setCopied(true);
      setTimeout(() => setCopied(false), 2400);
    } catch {
      // The reader closed the share sheet, or the clipboard is blocked in this browser: nothing to undo.
    }
  };
  return [share, copied] as const;
}

/**
 * Phones only (CSS shows it under 760 px, in place of the sign-in form): Google refuses sign-in inside
 * in-app browsers such as X's, and shepetal installs on a Mac anyway, so the useful step is sending the page there.
 */
export function SendToMac() {
  const [share, copied] = useShare();
  return (
    <div className="cta-mac">
      <button type="button" className="btn btn-lg" onClick={share}>
        {copied ? 'Link copied' : 'Send to my Mac'}
      </button>
    </div>
  );
}

/**
 * Phones only (CSS hides it from 760 px up): shepetal installs on a Mac, so on a phone the useful
 * step is getting this page onto the Mac. It appears once the hero's own button has scrolled away, and only
 * while no other trial button is on screen, so two of the same button never show at once.
 * On every width it also marks the header (data-cta), whose trial button turns solid once the hero's has gone.
 */
export function ShareBar() {
  const [shown, setShown] = useState(false);
  const [share, copied] = useShare();

  useEffect(() => {
    const hero = document.getElementById('hero-cta');
    const rows = [...document.querySelectorAll('.cta-row')];
    const head = document.querySelector<HTMLElement>('.site-head');
    if (!hero) return;
    const inView = new Set<Element>();
    const io = new IntersectionObserver((entries) => {
      for (const e of entries) e.isIntersecting ? inView.add(e.target) : inView.delete(e.target);
      const past = !inView.has(hero) && hero.getBoundingClientRect().top < 0;
      setShown(past && inView.size === 0);
      if (head) head.dataset.cta = past ? 'solid' : '';
    });
    rows.forEach((r) => io.observe(r));
    return () => io.disconnect();
  }, []);

  return (
    <div className="sharebar" data-shown={shown} aria-hidden={!shown}>
      <p>
        <b>shepetal is for Mac.</b> Send this page to your Mac to start.
      </p>
      <button type="button" className="btn" onClick={share} tabIndex={shown ? 0 : -1}>
        {copied ? 'Link copied' : 'Send to my Mac'}
      </button>
    </div>
  );
}
