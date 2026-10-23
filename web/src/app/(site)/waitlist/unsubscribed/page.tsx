import { noteMetadata, WaitlistNote } from '@/components/site/Waitlist';

export const metadata = noteMetadata('Unsubscribed');
export const dynamic = 'force-static';

export default function Unsubscribed() {
  return (
    <WaitlistNote title="Unsubscribed.">
      <p>Your address is deleted and you are off the waitlist, so the waitlist emails stop here.</p>
    </WaitlistNote>
  );
}
