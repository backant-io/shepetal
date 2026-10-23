import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { SiteHeader } from '@/components/site/Shell';
import { WaitlistForm } from '@/components/site/Waitlist';
import { pageMetadata } from '@/lib/seo';
import { waitlistOn } from '@/lib/waitlist-config';

export const metadata: Metadata = pageMetadata('waitlist', {
  title: 'Waitlist',
  description: 'shepetal is on the Mac today, and if you leave your email we will tell you when it comes to Windows, Linux or iPhone.',
});

// Prerendered and served from the cache: the Workers Free plan's 10 ms of CPU leaves no room for a render. The build
// fails if anything here reads the request. With WAITLIST off it is built as the 404 page.
export const dynamic = 'force-static';

export default function Waitlist() {
  if (!waitlistOn()) notFound();
  return (
    <>
      <SiteHeader end={<Link href="/faq" prefetch={false}>FAQ</Link>} />
      <main className="s-main s-legal s-waitlist">
        <h1 className="s-h2">The waitlist.</h1>
        <p className="s-lede">
          You probably use Windows, Linux or an iPhone and want shepetal there too, and today it is only on the Mac.
          Leave your email and we will write to you when it comes to yours.
        </p>
        <WaitlistForm />
        <p className="s-small">
          We only use your email to tell you when shepetal comes to a platform you chose. First we send you one email
          to confirm your address, and every email from us has a link that unsubscribes you and deletes your address.
          You can read the details in our <Link href="/privacy#waitlist" prefetch={false}>Privacy Policy</Link>.
        </p>
      </main>
    </>
  );
}
