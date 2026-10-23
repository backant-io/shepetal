import Link from 'next/link';
import { notFound } from 'next/navigation';
import { noteMetadata, WaitlistNote } from '@/components/site/Waitlist';
import { waitlistOn } from '@/lib/waitlist-config';

export const metadata = noteMetadata('Missing details');
export const dynamic = 'force-static';

export default function Check() {
  // Only the signup and the confirmation link lead here: with WAITLIST off, built as the 404 page.
  if (!waitlistOn()) notFound();
  return (
    <WaitlistNote title="Missing details.">
      <p>To join, enter your email, pick at least one platform and tick the box, and then send the form again.</p>
      <p>
        <Link href="/waitlist" prefetch={false}>Back to the waitlist</Link>
      </p>
    </WaitlistNote>
  );
}
