'use client';

import { useEffect, useState } from 'react';

/** Sends this page on: the share sheet where there is one, else the clipboard. `copied` is true for a moment after a copy. */
function useShare() {
  const [copied, setCopied] = useState(false);
  const share = async () => {
    const url = `${location.origin}/`;
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
      <p className="t-small muted">shepetal is for Mac. Send this page to your Mac and start your 30 free days there.</p>
    </div>
  );
}

/**
 * Phones only (CSS hides it from 760 px up): shepetal installs on a Mac, so on a phone the useful
 * step is getting this page onto the Mac. It appears once the hero's own button has scrolled away.
 */
export function ShareBar() {
  const [shown, setShown] = useState(false);
  const [share, copied] = useShare();

  useEffect(() => {
    const cta = document.getElementById('hero-cta');
    if (!cta) return;
    const io = new IntersectionObserver(([e]) => setShown(!e.isIntersecting && e.boundingClientRect.top < 0));
    io.observe(cta);
    return () => io.disconnect();
  }, []);

  return (
    <div className="sharebar" data-shown={shown} aria-hidden={!shown}>
      <p>
        <b>shepetal is for Mac.</b> Send this page to your Mac to start.
      </p>
      <button type="button" className="btn" onClick={share} tabIndex={shown ? 0 : -1}>
        {copied ? 'Link copied' : 'Send link'}
      </button>
    </div>
  );
}
