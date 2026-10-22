import type { Metadata } from 'next';
import Link from 'next/link';
import { SiteHeader } from '@/components/site/Shell';

export const metadata: Metadata = {
  title: 'Legal',
  description: 'The licenses, attribution and trademark notices for shepetal.',
  alternates: { canonical: '/legal' },
};

export default function Legal() {
  return (
    <>
      <SiteHeader end={<Link href="/account">Account</Link>} />
      <main className="s-main s-legal">
        <h1 className="s-h2">Legal</h1>

        <div className="s-prose">
          <h2>Who we are</h2>
          <p>
            The <Link href="/impressum">legal notice (Impressum)</Link> names who runs shepetal and how to reach us. The{' '}
            <Link href="/terms">Terms of Use</Link>, the <Link href="/refunds">Refund Policy</Link> and the{' '}
            <Link href="/privacy">Privacy Policy</Link> are their own pages.
          </p>

          <h2>Fonts</h2>
          <p>
            Archivo, Bodoni Moda and Fragment Mono are under the SIL Open Font License 1.1:{' '}
            <a href="/fonts/licenses/Archivo-OFL.txt">Archivo license</a>,{' '}
            <a href="/fonts/licenses/BodoniModa-OFL.txt">Bodoni Moda license</a> and{' '}
            <a href="/fonts/licenses/FragmentMono-OFL.txt">Fragment Mono license</a>.
          </p>

          <h2>Emoji</h2>
          <p>
            The <img className="s-shush" src="/brand/emoji/emoji_u1f92b.svg" alt="🤫" width={18} height={18} /> artwork
            is Noto Color Emoji by Google, under the Apache License 2.0:{' '}
            <a href="/brand/emoji/LICENSE-Apache-2.0.txt">license</a> and <a href="/brand/emoji/NOTICE.txt">notice</a>.
          </p>

          <h2>Trademarks</h2>
          <p>Mac and macOS are trademarks of Apple Inc., registered in the U.S. and other countries and regions.</p>

          <p>© 2026 Backant Inc.</p>
        </div>
      </main>
    </>
  );
}
