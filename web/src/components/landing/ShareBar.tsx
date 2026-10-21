'use client';

import { useEffect, useState } from 'react';

/**
 * Phones only (CSS hides it from 760 px up): shepetal installs on a Mac, so on a phone the useful
 * step is getting this page onto the Mac. It appears once the hero's own button has scrolled away.
 */
export function ShareBar() {
  const [shown, setShown] = useState(false);
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    const cta = document.getElementById('hero-cta');
    if (!cta) return;
    const io = new IntersectionObserver(([e]) => setShown(!e.isIntersecting && e.boundingClientRect.top < 0));
    io.observe(cta);
    return () => io.disconnect();
  }, []);

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
