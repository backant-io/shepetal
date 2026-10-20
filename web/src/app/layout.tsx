import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'Shepetal',
  description: 'Dictation that runs fully on your Mac. Hold fn to talk. Nothing leaves your computer.',
  metadataBase: new URL('https://shepetal.backant.io'),
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
