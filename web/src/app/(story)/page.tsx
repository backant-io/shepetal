import type { Metadata } from 'next';
import { Story } from '@/components/story/Story';
import { jsonLd, pageMetadata, softwareJsonLd } from '@/lib/seo';

export const metadata: Metadata = pageMetadata('home', {
  description: 'Press one key. Your words appear wherever you speak. Dictation for Mac: your voice never leaves it.',
});

export default function Home() {
  return (
    <>
      <Story />
      {/* the app, its two offers and who makes it, for search engines */}
      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: jsonLd(softwareJsonLd()) }} />
    </>
  );
}
