import Link from 'next/link';
import { noteMetadata, WaitlistNote } from '@/components/site/Waitlist';
import { waitlistOn } from '@/lib/waitlist-config';

export const metadata = noteMetadata('This link does not work');
export const dynamic = 'force-static';

/** A confirmation or unsubscribe link that is not signed, is older than 7 days, or came before an unsubscribe. */
export default function BadLink() {
  return (
    <WaitlistNote title="This link does not work.">
      <p>It is too old or incomplete.</p>
      {waitlistOn() && (
        <p>
          Sign up again, and we send you a new one. <Link href="/waitlist" prefetch={false}>Back to the waitlist</Link>
        </p>
      )}
    </WaitlistNote>
  );
}
