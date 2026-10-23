import { noteMetadata, WaitlistNote } from '@/components/site/Waitlist';

export const metadata = noteMetadata('Unsubscribe');
export const dynamic = 'force-static';

/**
 * The unsubscribe link opens this page, and its button unsubscribes: a link checker that opens every link in an email
 * never does (RFC 8058). The page is static; worker.ts puts the link's signed ?t= into the hidden field (withEdgeHtml).
 */
export default function Unsubscribe() {
  return (
    <WaitlistNote title="Unsubscribe.">
      <p>Click the button and we stop the waitlist emails for shepetal on Windows, Linux and iPhone and delete your address.</p>
      <form className="s-wl" method="post" action="/api/waitlist/unsubscribe">
        <input type="hidden" name="t" value="" />
        <button type="submit" className="s-btn">
          Unsubscribe
        </button>
      </form>
    </WaitlistNote>
  );
}
