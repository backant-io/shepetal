import Link from 'next/link';
import { noteMetadata, WaitlistNote } from '@/components/site/Waitlist';
import { waitlistOn } from '@/lib/waitlist-config';

export const metadata = noteMetadata('Invalid link');
export const dynamic = 'force-static';

/** A confirmation or unsubscribe link that is not signed, is older than 7 days, or came before an unsubscribe. */
export default function BadLink() {
  return (
    <WaitlistNote title="Invalid link.">
      <p>The link you clicked is too old or incomplete.</p>
      {waitlistOn() && (
        <p>
          Just sign up again and we will send you a new one. <Link href="/waitlist" prefetch={false}>Back to the waitlist</Link>
        </p>
      )}
    </WaitlistNote>
  );
}
