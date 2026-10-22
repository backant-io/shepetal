import type { Metadata } from 'next';
import { pageMetadata } from '@/lib/seo';
import Link from 'next/link';
import { SiteHeader } from '@/components/site/Shell';
import { releasesHtml } from '@/lib/changelog';

export const metadata: Metadata = pageMetadata('changelog', { title: 'Changelog', description: 'Every shepetal release for Mac: what changed, and when.' });

/**
 * Static. worker.ts puts the releases on R2 into [data-releases] on every visit (releasesHtml), so a promotion shows up
 * without a deploy. Built with the empty state; hydration leaves the container's HTML alone. Links here are plain <a>:
 * a client navigation would show the built, empty list.
 */
export default function Changelog() {
  return (
    <>
      <SiteHeader end={<Link href="/account" prefetch={false}>Account</Link>} />
      <main className="s-main s-legal s-changelog">
        <h1 className="s-h2">Changelog.</h1>
        <p className="s-mono">shepetal for Mac</p>
        <div data-releases="" dangerouslySetInnerHTML={{ __html: releasesHtml([]) }} />
        <div className="s-prose">
          <p>
            <a href="/install">Download the latest version</a>. shepetal updates itself once it is installed.
          </p>
        </div>
      </main>
    </>
  );
}
