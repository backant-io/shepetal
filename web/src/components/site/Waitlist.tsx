import Link from 'next/link';
import { SiteHeader } from '@/components/site/Shell';
import { CONSENT_TEXT, PLATFORMS, waitlistOn } from '@/lib/waitlist-config';

/**
 * The waitlist form. A plain form POST to /api/waitlist (worker.ts answers it without Next), so it works without
 * JavaScript; the browser asks for the email and the consent box, the Worker for at least one platform. Nothing at
 * all while WAITLIST is off.
 */
export function WaitlistForm() {
  if (!waitlistOn()) return null;
  return (
    <form className="s-wl" method="post" action="/api/waitlist">
      <div className="s-field">
        <label className="s-label" htmlFor="wl-email">
          Email
        </label>
        <input className="s-input s-input-plain" id="wl-email" name="email" type="email" autoComplete="email" maxLength={254} required />
      </div>
      <fieldset className="s-wl-set">
        <legend className="s-label">Your platforms, one or more</legend>
        {Object.entries(PLATFORMS).map(([value, name]) => (
          <label key={value} className="s-check">
            <input type="checkbox" name="platform" value={value} />
            {name}
          </label>
        ))}
      </fieldset>
      <label className="s-check">
        <input type="checkbox" name="consent" value="yes" required />
        {CONSENT_TEXT}
      </label>
      <button type="submit" className="s-btn s-btn-signal">
        Join the waitlist
      </button>
    </form>
  );
}

/** A page after the form or a link: the header, one heading, a few lines. */
export function WaitlistNote({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <>
      <SiteHeader end={<Link href="/faq" prefetch={false}>FAQ</Link>} />
      <main className="s-main s-legal s-waitlist">
        <h1 className="s-h2">{title}</h1>
        <div className="s-prose">{children}</div>
      </main>
    </>
  );
}

/** For the pages after the form: static, and kept out of search. */
export const noteMetadata = (title: string) => ({ title, robots: { index: false } });
