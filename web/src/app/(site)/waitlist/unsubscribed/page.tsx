import { noteMetadata, WaitlistNote } from '@/components/site/Waitlist';

export const metadata = noteMetadata('You are unsubscribed');
export const dynamic = 'force-static';

export default function Unsubscribed() {
  return (
    <WaitlistNote title="You are unsubscribed.">
      <p>You get no more waitlist emails. We delete your address within 30 days.</p>
    </WaitlistNote>
  );
}
