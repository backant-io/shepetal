import { noteMetadata, WaitlistNote } from '@/components/site/Waitlist';

export const metadata = noteMetadata('You are on the list');
export const dynamic = 'force-static';

export default function Confirmed() {
  return (
    <WaitlistNote title="You are on the list.">
      <p>We write when shepetal comes to your platform. Every email has an unsubscribe link.</p>
    </WaitlistNote>
  );
}
