import Link from 'next/link';
import { noteMetadata, WaitlistNote } from '@/components/site/Waitlist';

export const metadata = noteMetadata('Something is missing');
export const dynamic = 'force-static';

export default function Check() {
  return (
    <WaitlistNote title="Something is missing.">
      <p>Enter your email, choose at least one platform and tick the box.</p>
      <p>
        <Link href="/waitlist">Back to the waitlist</Link>
      </p>
    </WaitlistNote>
  );
}
