import type { Metadata, Viewport } from 'next';
import Link from 'next/link';
import { SiteHeader } from '@/components/landing/SiteHeader';
import { SignInButton } from '@/components/SignInButton';
import '@/brand/tokens.css';
import './fonts.css';
import './site.css';
import './landing.css';

const title = 'shepetal: dictation that stays on your Mac';
const description = 'Instant dictation that stays on your Mac. Press one key. Your words appear wherever you speak.';
// Built from web/og/og.html (headless Chrome, then JPEG); the brand keeps the price and the steps off link previews.
// A static file, so link previews (X, iMessage, Slack) get it from the edge without waking the Worker.
const ogImage = {
  url: '/og.jpg',
  width: 1200,
  height: 630,
  type: 'image/jpeg',
  alt: 'shepetal. Instant dictation that stays on your Mac. Illustration: the shepetal indicator with its ring, and a spoken prompt landed in a terminal.',
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
      <a href="#content" className="skip">
        Skip to content
      </a>
      <SiteHeader
        cta={
          <SignInButton redirectTo="/account" className="btn btn-line">
            Try 30 days free
          </SignInButton>
        }
      />
      <div id="content" className="flex-1">
        {children}
      </div>
      <footer className="site-foot">
        <div className="wrap">
          <div className="foot-grid">
            <div>
              <picture>
                <source srcSet="/brand/shepetal-wordmark-small-on-dark.svg" media="(prefers-color-scheme: dark)" />
                <img src="/brand/shepetal-wordmark-small-on-light.svg" alt="shepetal" width={119} height={32} />
              </picture>
              <p style={{ marginTop: 14 }}>Dictation for Mac by Pavel Hegler, from Slovenia.</p>
            </div>
            <nav className="foot-links" aria-label="Site">
              <Link href="/privacy">Privacy</Link>
              <Link href="/terms">Terms</Link>
              <Link href="/legal">Legal</Link>
            </nav>
          </div>
        </div>
      </footer>
    </div>
  );
}
