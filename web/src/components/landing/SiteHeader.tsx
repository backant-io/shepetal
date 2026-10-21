'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

const NAV = [
  ['Meetings', '/#meetings'],
  ['Pricing', '/#price'],
];

/** The site header. The home page has the trial button; the other pages have the account. */
export function SiteHeader({ cta }: { cta: React.ReactNode }) {
  const home = usePathname() === '/';
  return (
    <header className="site-head">
      <div className="wrap site-head-in">
        <Link href="/" className="block" aria-label="shepetal home">
          <picture>
            <source srcSet="/brand/shepetal-wordmark-small-on-dark.svg" media="(prefers-color-scheme: dark)" />
            <img src="/brand/shepetal-wordmark-small-on-light.svg" alt="shepetal" width={119} height={32} />
          </picture>
        </Link>
        <nav className="site-nav" aria-label="Sections">
          {NAV.map(([label, href]) => (
            <a key={href} href={home ? href.slice(1) : href}>
              {label}
            </a>
          ))}
        </nav>
        <div className="head-end">
          {home ? (
            cta
          ) : (
            <Link href="/account" className="head-link">
              Account
            </Link>
          )}
        </div>
      </div>
    </header>
  );
}
