import type { Metadata, Viewport } from 'next';
import { Funnel_Display, Funnel_Sans } from 'next/font/google';
import Link from 'next/link';
import './site.css';

const display = Funnel_Display({ subsets: ['latin'], weight: ['300', '400'], variable: '--font-display' });
const sans = Funnel_Sans({ subsets: ['latin'], weight: ['400', '500', '600'], variable: '--font-sans' });

const description =
  'Dictation that runs fully on your Mac with on-device speech recognition. Hold fn, talk, and the text lands where your cursor is. Free for 30 days, then $4.99 once.';

export const metadata: Metadata = {
  title: { default: 'Shepetal: hold fn, talk, done', template: '%s - Shepetal' },
  description,
  openGraph: { title: 'Shepetal: hold fn, talk, done', description, url: '/', siteName: 'Shepetal', type: 'website' },
  twitter: { card: 'summary_large_image', title: 'Shepetal: hold fn, talk, done', description },
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
