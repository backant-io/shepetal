import type { Metadata, Viewport } from 'next';
import Link from 'next/link';
import '@/brand/tokens.css';
import './site.css';

const description =
  'Dictation that runs fully on your Mac with on-device speech recognition. Hold fn, talk, and the text lands where your cursor is. Free for 30 days, then $4.99 once.';

// The tab icon is the š mark. 🤫 is the brand's documented alternative (BRAND.md): set 'emoji' to use it alone.
const FAVICON = 'mark' as 'mark' | 'emoji';

export const metadata: Metadata = {
  title: { default: 'shepetal: hold fn, talk, done', template: '%s - shepetal' },
  description,
  openGraph: { title: 'shepetal: hold fn, talk, done', description, url: '/', siteName: 'shepetal', type: 'website' },
  twitter: { card: 'summary_large_image', title: 'shepetal: hold fn, talk, done', description },
  icons:
    FAVICON === 'mark'
      ? {
          icon: [
            { url: '/favicon.svg', type: 'image/svg+xml' },
            { url: '/favicon-32.png', sizes: '32x32', type: 'image/png' },
            { url: '/favicon-16.png', sizes: '16x16', type: 'image/png' },
          ],
          apple: '/apple-touch-icon.png',
        }
      : { icon: { url: '/favicon-emoji.svg', type: 'image/svg+xml' } },
};

export const viewport: Viewport = {
  themeColor: [
    { media: '(prefers-color-scheme: light)', color: '#E9E9E5' },
    { media: '(prefers-color-scheme: dark)', color: '#0B121E' },
  ],
};

export default function SiteLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex min-h-screen flex-col">
      <header className="mx-auto flex w-full max-w-6xl items-center justify-between px-4 py-5 sm:px-8">
        <Link href="/" className="block">
          <picture>
            <source srcSet="/brand/shepetal-wordmark-small-on-dark.svg" media="(prefers-color-scheme: dark)" />
            <img src="/brand/shepetal-wordmark-small-on-light.svg" alt="shepetal" width={119} height={32} />
          </picture>
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
