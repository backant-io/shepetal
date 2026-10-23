import { notFound } from 'next/navigation';
import { noteMetadata, WaitlistNote } from '@/components/site/Waitlist';
import { waitlistOn } from '@/lib/waitlist-config';

export const metadata = noteMetadata('You are on the list');
export const dynamic = 'force-static';

export default function Confirmed() {
  // Only the signup and the confirmation link lead here: with WAITLIST off, built as the 404 page.
  if (!waitlistOn()) notFound();
  return (
    <WaitlistNote title="You are on the list.">
      <p>We write when shepetal comes to your platform. Every email has an unsubscribe link.</p>
    </WaitlistNote>
  );
}
