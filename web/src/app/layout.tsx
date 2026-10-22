import type { Metadata, Viewport } from 'next';
import { preload } from 'react-dom';
import { Analytics } from '@/components/Analytics';
import { ogImage } from '@/lib/seo';
import { SITE_URL } from '@/lib/site';
import '@/styles/system.css';

const title = 'shepetal: press one key, your words appear';
const description = 'Press one key. Your words appear wherever you speak. Dictation for Mac: your voice never leaves it.';
// Static files, so link previews (X, iMessage, Slack) get them from the edge without waking the Worker. Each public
// page has its own (src/lib/seo.ts, rendered by og/pages.mjs); this is the default. No price on a preview.
const preview = ogImage('home');

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: { default: title, template: '%s - shepetal' },
  description,
  openGraph: {
    title,
    description,
    url: '/',
    siteName: 'shepetal',
    type: 'website',
    locale: 'en_US',
    images: [preview],
  },
  twitter: { card: 'summary_large_image', title, description, images: [preview] },
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

export const viewport: Viewport = { themeColor: '#E6E4DE', colorScheme: 'light' };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  // Archivo draws the headline, the largest paint: without this the browser finds it only after the CSS.
  preload('/fonts/archivo-latin.woff2', { as: 'font', type: 'font/woff2', crossOrigin: '' });
  return (
    <html lang="en">
      <body>
        {children}
        <Analytics />
      </body>
    </html>
  );
}
