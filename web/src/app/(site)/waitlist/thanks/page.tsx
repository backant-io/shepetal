import { notFound } from 'next/navigation';
import { noteMetadata, WaitlistNote } from '@/components/site/Waitlist';
import { waitlistOn } from '@/lib/waitlist-config';

export const metadata = noteMetadata('Check your email');
export const dynamic = 'force-static';

/** After every signup, whatever the address: the page never says whether it was on the list already. */
export default function Thanks() {
  // Only the signup and the confirmation link lead here: with WAITLIST off, built as the 404 page.
  if (!waitlistOn()) notFound();
  return (
    <WaitlistNote title="Check your email.">
      <p>Click the link in our email to join the waitlist. It works for 7 days.</p>
      <p>No email? Look in your spam folder, or sign up again in 30 minutes.</p>
    </WaitlistNote>
  );
}
