import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { SiteHeader } from '@/components/site/Shell';
import { WaitlistForm } from '@/components/site/Waitlist';
import { pageMetadata } from '@/lib/seo';
import { waitlistOn } from '@/lib/waitlist-config';

export const metadata: Metadata = pageMetadata('waitlist', {
  title: 'Waitlist',
  description: 'shepetal is for Mac today. Leave your email to hear when it comes to Windows, Linux or iPhone.',
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
        <h1 className="s-h2">Windows, Linux and iPhone.</h1>
        <p className="s-lede">shepetal is for Mac today. Leave your email, and we write when it comes to yours.</p>
        <WaitlistForm />
        <p className="s-small">
          We use your email for one thing: to tell you when shepetal comes to a platform you chose. First we send one
          email to confirm your address. Every email has a link that unsubscribes you and deletes your address.{' '}
          <Link href="/privacy#waitlist" prefetch={false}>Privacy Policy</Link>.
        </p>
      </main>
    </>
  );
}
