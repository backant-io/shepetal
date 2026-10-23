import { notFound } from 'next/navigation';
import { noteMetadata, WaitlistNote } from '@/components/site/Waitlist';
import { waitlistOn } from '@/lib/waitlist-config';

export const metadata = noteMetadata('Confirmed');
export const dynamic = 'force-static';

export default function Confirmed() {
  // Only the signup and the confirmation link lead here: with WAITLIST off, built as the 404 page.
  if (!waitlistOn()) notFound();
  return (
    <WaitlistNote title="Confirmed.">
      <p>
        Thanks, your address is confirmed and we will email you when shepetal comes to a platform you chose, and every
        email from us has a link to unsubscribe.
      </p>
    </WaitlistNote>
  );
}
