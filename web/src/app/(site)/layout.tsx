import type { Metadata, Viewport } from 'next';
import Link from 'next/link';
import { Shush } from '@/components/landing/Mac';
import { SiteHeader } from '@/components/landing/SiteHeader';
import { SignInButton } from '@/components/SignInButton';
import '@/brand/tokens.css';
import './fonts.css';
import './site.css';
import './landing.css';

const title = 'shepetal: dictation that stays on your Mac';
const description =
  'Quiet dictation for the Mac. Press one key. Your words appear wherever you speak, and your voice stays on your Mac.';
// brand/assets/og/og-dark.png as a JPEG; the brand keeps the price and the steps off link previews.
// A static file, so link previews (X, iMessage, Slack) get it from the edge without waking the Worker.
const ogImage = {
  url: '/og.jpg',
  width: 1200,
  height: 630,
  type: 'image/jpeg',
  alt: 'shepetal. Quiet dictation for the Mac. Instant dictation that stays on your Mac. Press one key. Your words appear wherever you speak.',
};

export const metadata: Metadata = {
  title: { default: title, template: '%s - shepetal' },
  description,
  openGraph: { title, description, url: '/', siteName: 'shepetal', type: 'website', locale: 'en_US', images: [ogImage] },
  twitter: { card: 'summary_large_image', title, description, images: [ogImage] },
  // The tab and app icons are the Noto 🤫 (BRAND.md).
  icons: {
    icon: [
      { url: '/favicon.ico', sizes: '48x48' },
      { url: '/favicon.svg', type: 'image/svg+xml' },
    ],
    apple: '/apple-touch-icon.png',
  },
  manifest: '/site.webmanifest',
};

export const viewport: Viewport = {
  themeColor: [
    { media: '(prefers-color-scheme: light)', color: '#FAEEE8' },
    { media: '(prefers-color-scheme: dark)', color: '#1C0A13' },
  ],
};

export default function SiteLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex min-h-screen flex-col">
      <SiteHeader
        cta={
          <SignInButton redirectTo="/account" className="btn">
            Try 30 days free
          </SignInButton>
        }
      />
      <div className="flex-1">{children}</div>
      <footer className="site-foot">
        <div className="wrap">
          <div className="foot-grid">
            <div>
              <picture>
                <source srcSet="/brand/shepetal-wordmark-small-on-dark.svg" media="(prefers-color-scheme: dark)" />
                <img src="/brand/shepetal-wordmark-small-on-light.svg" alt="shepetal" width={119} height={32} />
              </picture>
              <p style={{ marginTop: 14 }}>Dictation for Mac, made in Slovenia by Pavel Hegler.</p>
            </div>
            <nav className="foot-links" aria-label="Site">
              <Link href="/account">Account</Link>
              <Link href="/privacy">Privacy</Link>
              <Link href="/terms">Terms</Link>
            </nav>
          </div>
          <div className="foot-small">
            <p>This site loads no trackers and serves its own fonts.</p>
            <p>
              The <Shush size={14} /> artwork is Noto Color Emoji by Google, under the Apache License 2.0:{' '}
              <a href="/brand/emoji/LICENSE-Apache-2.0.txt">license</a> and <a href="/brand/emoji/NOTICE.txt">notice</a>.
            </p>
            <p>Mac and macOS are trademarks of Apple Inc., registered in the U.S. and other countries and regions.</p>
            <p>© 2026 Backant Inc.</p>
          </div>
        </div>
      </footer>
    </div>
  );
}
