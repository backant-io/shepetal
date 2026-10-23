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
      <p>Open the email from us and click the link in it to join the waitlist, and you have 7 days to do that.</p>
      <p>If you can't find it, look in your spam folder or sign up again in 30 minutes.</p>
    </WaitlistNote>
  );
}
