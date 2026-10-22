import type { Metadata } from 'next';
import { siteOrigin } from '@/lib/site';
import './globals.css';

export const metadata: Metadata = {
  title: 'shepetal',
  description: 'Instant dictation that stays on your Mac.',
  // OG and canonical URLs resolve against https://<SHEPETAL_DOMAIN> (inlined at build by next.config.ts).
  metadataBase: new URL(siteOrigin()),
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
