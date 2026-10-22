import type { Metadata } from 'next';
import { pageMetadata } from '@/lib/seo';
import Link from 'next/link';
import { SiteHeader } from '@/components/site/Shell';
import { type Release, releasesOf } from '@/lib/changelog';
import { releases } from '@/lib/download';

export const metadata: Metadata = pageMetadata('changelog', { title: 'Changelog', description: 'Every shepetal release for Mac: what changed, and when.' });

// Read from the releases on R2 at request time, so a promotion shows up without a deploy.
export const dynamic = 'force-dynamic';

const day = (iso: string) => new Date(iso).toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC' });

async function published(): Promise<Release[]> {
  try {
    return await releasesOf(releases());
  } catch {
    return []; // no bucket (a preview without R2) or a bad latest.json: the page still answers
  }
}

export default async function Changelog() {
  const list = await published();
  return (
    <>
      <SiteHeader end={<Link href="/account" prefetch={false}>Account</Link>} />
      <main className="s-main s-legal s-changelog">
        <h1 className="s-h2">Changelog.</h1>
        <p className="s-mono">shepetal for Mac</p>
        {list.length === 0 ? (
          <div className="s-prose">
            <p>The first release is on its way. It will be listed here the day it ships.</p>
          </div>
        ) : (
          <ol className="s-releases">
            {list.map((r, i) => (
              <li key={r.version}>
                <h2 className="s-release-title">
                  {r.version}
                  {i === 0 && <span className="s-mono s-release-tag">Latest</span>}
                </h2>
                <p className="s-mono">
                  {[r.date && day(r.date), r.minimumSystem && `macOS ${r.minimumSystem} or later`].filter(Boolean).join(' · ')}
                </p>
                {r.notes.length > 0 && (
                  <ul className="s-release-notes">
                    {r.notes.map((n) => (
                      <li key={n}>{n}</li>
                    ))}
                  </ul>
                )}
              </li>
            ))}
          </ol>
        )}
        <div className="s-prose">
          <p>
            <a href="/install">Download the latest version</a>. shepetal updates itself once it is installed.
          </p>
        </div>
      </main>
    </>
  );
}
