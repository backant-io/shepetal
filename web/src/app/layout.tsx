import type { Metadata, Viewport } from 'next';
import { preload } from 'react-dom';
import { SITE_URL } from '@/lib/site';
import '@/styles/system.css';

const title = 'shepetal: press one key, your words appear';
const description = 'Press one key. Your words appear wherever you speak. 100% private dictation for Mac.';
// A static file, so link previews (X, iMessage, Slack) get it from the edge without waking the Worker.
// Built from web/og/og.html in headless Chrome. The brand keeps the price off link previews.
const ogImage = {
  url: '/og.jpg',
  width: 1200,
  height: 630,
  type: 'image/jpeg',
  alt: 'shepetal. Press one key. The orange fn key on a concrete-white ground.',
};

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
    images: [ogImage],
  },
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

export const viewport: Viewport = { themeColor: '#E6E4DE', colorScheme: 'light' };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  // Archivo draws the headline, the largest paint: without this the browser finds it only after the CSS.
  preload('/fonts/archivo-latin.woff2', { as: 'font', type: 'font/woff2', crossOrigin: '' });
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
