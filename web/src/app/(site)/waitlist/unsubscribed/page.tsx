import { noteMetadata, WaitlistNote } from '@/components/site/Waitlist';

export const metadata = noteMetadata('You are unsubscribed');
export const dynamic = 'force-static';

export default function Unsubscribed() {
  return (
    <WaitlistNote title="You are unsubscribed.">
      <p>You get no more waitlist emails, and your address is deleted.</p>
    </WaitlistNote>
  );
}
