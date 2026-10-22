import type { Metadata } from 'next';
import Link from 'next/link';
import { InstallSteps } from '@/components/site/InstallSteps';
import { attribution, attributionQuery } from '@/lib/analytics';
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
 * installer, so the browser stays here.
 */
export default async function Install({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const q = await searchParams;
  // where the visitor came from (?ref=, utm_*), carried on to the download, which counts it
  const download = `/download${attributionQuery(attribution({ get: (k: string) => q[k] }))}`;
  return (
    <>
      {/* React puts this in <head>: start the download a moment after the page shows. */}
      <meta httpEquiv="refresh" content={`1;url=${download}`} />
      <SiteHeader end={<Link href="/account">Account</Link>} />
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
