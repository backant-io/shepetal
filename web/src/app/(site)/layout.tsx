import type { Metadata, Viewport } from 'next';
import { Funnel_Display, Funnel_Sans } from 'next/font/google';
import Link from 'next/link';
import './site.css';

const display = Funnel_Display({ subsets: ['latin'], weight: ['300', '400'], variable: '--font-display' });
const sans = Funnel_Sans({ subsets: ['latin'], weight: ['400', '500', '600'], variable: '--font-sans' });

const title = 'shepetal: Write at the speed of thought.';
const description =
  'Press one key. Your words appear wherever you speak. Dictation that runs fully on your Mac with on-device speech recognition. Free for 30 days, then $4.99 once.';
// A static file in public/, served from the edge without waking the Worker.
const ogImage = {
  url: '/og.png',
  width: 1200,
  height: 630,
  type: 'image/png',
  alt: 'shepetal. Instant dictation that stays on your Mac. Press one key. Your words appear wherever you speak.',
};

export const metadata: Metadata = {
  title: { default: title, template: '%s - Shepetal' },
  description,
  openGraph: { title, description, url: '/', siteName: 'Shepetal', type: 'website', images: [ogImage] },
  twitter: { card: 'summary_large_image', title, description, images: [ogImage] },
};

export const viewport: Viewport = {
  themeColor: [
    { media: '(prefers-color-scheme: light)', color: '#e9ecf2' },
    { media: '(prefers-color-scheme: dark)', color: '#161a2e' },
  ],
};

export default function SiteLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className={`${display.variable} ${sans.variable} flex min-h-screen flex-col font-[family-name:var(--font-sans)]`}>
      <header className="mx-auto flex w-full max-w-6xl items-center justify-between px-4 py-5 sm:px-8">
        <Link href="/" className="flex items-center gap-2 text-lg font-semibold tracking-tight">
          <span aria-hidden="true">🤫</span>
          shepetal
        </Link>
        <Link href="/account" className="text-sm font-medium text-[var(--hush)] hover:text-[var(--ink)]">
          Account
        </Link>
      </header>
      <div className="flex-1">{children}</div>
      <footer className="mx-auto flex w-full max-w-6xl flex-wrap items-center gap-x-6 gap-y-2 px-4 pb-12 pt-24 text-sm text-[var(--hush)] sm:px-8">
        <span>© 2026 Backant Inc.</span>
        <Link href="/privacy" className="hover:text-[var(--ink)]">
          Privacy
        </Link>
        <Link href="/terms" className="hover:text-[var(--ink)]">
          Terms
        </Link>
      </footer>
    </div>
  );
}
