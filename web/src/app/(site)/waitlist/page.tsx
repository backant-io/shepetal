import type { Metadata } from 'next';
import Link from 'next/link';
import { SiteHeader } from '@/components/site/Shell';
import { WaitlistForm } from '@/components/site/Waitlist';
import { pageMetadata } from '@/lib/seo';

export const metadata: Metadata = pageMetadata('waitlist', {
  title: 'Waitlist',
  description: 'shepetal is for Mac today. Leave your email to hear when it comes to Windows, Linux or iPhone.',
});

// Prerendered and served from the cache: the Workers Free plan's 10 ms of CPU leaves no room for a render. The build
// fails if anything here reads the request.
export const dynamic = 'force-static';

export default function Waitlist() {
  return (
    <>
      <SiteHeader end={<Link href="/faq">FAQ</Link>} />
      <main className="s-main s-legal s-waitlist">
        <h1 className="s-h2">Windows, Linux and iPhone.</h1>
        <p className="s-lede">shepetal is for Mac today. Leave your email, and we write when it comes to yours.</p>
        <WaitlistForm />
        <p className="s-small">
          First we send one email to confirm your address. After that, we write only when shepetal comes to a platform
          you chose. Every email has an unsubscribe link. <Link href="/privacy">Privacy Policy</Link>.
        </p>
      </main>
    </>
  );
}
