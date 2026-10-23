import Link from 'next/link';
import { notFound } from 'next/navigation';
import { noteMetadata, WaitlistNote } from '@/components/site/Waitlist';
import { waitlistOn } from '@/lib/waitlist-config';

export const metadata = noteMetadata('Something is missing');
export const dynamic = 'force-static';

export default function Check() {
  // Only the signup and the confirmation link lead here: with WAITLIST off, built as the 404 page.
  if (!waitlistOn()) notFound();
  return (
    <WaitlistNote title="Something is missing.">
      <p>Enter your email, choose at least one platform and tick the box.</p>
      <p>
        <Link href="/waitlist" prefetch={false}>Back to the waitlist</Link>
      </p>
    </WaitlistNote>
  );
}
