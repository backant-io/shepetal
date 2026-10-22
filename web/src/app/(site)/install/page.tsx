import type { Metadata } from 'next';
import Link from 'next/link';
import { InstallSteps } from '@/components/site/InstallSteps';
import { SiteHeader } from '@/components/site/Shell';

export const metadata: Metadata = {
  title: 'Install shepetal',
  description: 'Drag shepetal into Applications, then allow it once in Privacy & Security.',
  alternates: { canonical: '/install' },
  robots: { index: false },
};

/**
 * The moment after Download (the landing page's Try 30 days free and the account's Download button land here): the
 * download starts by itself, and the page says how to install an app macOS cannot verify. /download answers with the
 * installer, so the browser stays here. The page is static: worker.ts adds the refresh that starts the download and
 * carries ?ref= and utm_* on to it and to the link, at the edge (withEdgeHtml). React must not render that refresh.
 */
export default function Install() {
  const download = '/download';
  return (
    <>
      <SiteHeader end={<Link href="/account" prefetch={false}>Account</Link>} />
      <main className="s-main s-legal s-install">
        <h1 className="s-h2">Thanks. Here’s how to install it.</h1>
        <p className="s-mono">
          Your download starts by itself. If it does not, <a href={download}>download shepetal</a>.
        </p>
        <InstallSteps />
        <p className="s-small">
          Stuck? The <Link href="/faq">FAQ</Link> has more, or write to{' '}
          <a href="mailto:support@shepetal.app">support@shepetal.app</a>.
        </p>
      </main>
    </>
  );
}
