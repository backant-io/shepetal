import type { Metadata } from 'next';
import { Shush } from '@/components/landing/Mac';

export const metadata: Metadata = {
  title: 'Legal',
  description: 'The licenses, attribution and trademark notices for shepetal.',
  alternates: { canonical: '/legal' },
};

export default function Legal() {
  return (
    <main className="mx-auto max-w-3xl px-4 pt-16 sm:px-8">
      <h1 className="display text-[clamp(2.75rem,8vw,4.5rem)] leading-none">Legal</h1>

      <div className="prose-legal mt-12">
        <h2>Fonts</h2>
        <p>
          Newsreader and Hanken Grotesk are under the SIL Open Font License 1.1:{' '}
          <a href="/brand/fonts/Newsreader-OFL.txt">Newsreader license</a> and{' '}
          <a href="/brand/fonts/HankenGrotesk-OFL.txt">Hanken Grotesk license</a>.
        </p>

        <h2>Emoji</h2>
        <p>
          The <Shush size={16} /> artwork is Noto Color Emoji by Google, under the Apache License 2.0:{' '}
          <a href="/brand/emoji/LICENSE-Apache-2.0.txt">license</a> and <a href="/brand/emoji/NOTICE.txt">notice</a>.
        </p>

        <h2>Trademarks</h2>
        <p>Mac and macOS are trademarks of Apple Inc., registered in the U.S. and other countries and regions.</p>

        <p>© 2026 Backant Inc.</p>
      </div>
    </main>
  );
}
