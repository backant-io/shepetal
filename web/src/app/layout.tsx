import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'shepetal',
  description: 'Quiet dictation for the Mac. Your voice stays on your Mac.',
  metadataBase: new URL('https://shepetal.backant.io'),
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
