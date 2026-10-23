import type { Metadata } from 'next';
import Link from 'next/link';
import { SiteFooter, SiteHeader } from '@/components/site/Shell';
import '@/styles/site.css';

export const metadata: Metadata = { title: 'Page not found' };

/**
 * Every unknown path (worker.ts and OpenNext answer them with this prerendered page): the site's header and footer, so
 * the Privacy Policy and "Verträge hier kündigen" are reachable from here too.
 */
export default function NotFound() {
  return (
    <div className="s-page">
      <SiteHeader />
      <main className="s-main s-legal">
        <h1 className="s-h2">Page not found.</h1>
        <div className="s-prose">
          <p>
            There is nothing at this address. <Link href="/">Back to shepetal</Link>
          </p>
        </div>
      </main>
      <SiteFooter />
    </div>
  );
}
