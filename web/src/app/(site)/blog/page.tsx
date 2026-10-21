import type { Metadata } from 'next';
import { BlogCta, Cards } from '@/components/blog/parts';
import { ARTICLES } from '@/lib/blog/articles';
import { blogJsonLd, ldJson } from '@/lib/blog/seo';

const title = 'Dictation apps compared: the shepetal blog';
const description =
  'Wispr Flow, Superwhisper, MacWhisper, Apple Dictation and more, side by side: prices, platforms, offline use and where your voice goes. Ranked for Mac.';

export const metadata: Metadata = {
  title: { absolute: title },
  description,
  alternates: { canonical: '/blog' },
  openGraph: {
    type: 'website',
    url: '/blog',
    title,
    description,
    siteName: 'shepetal',
    locale: 'en_US',
    images: [{ url: '/blog/og/blog.jpg', width: 1200, height: 630, type: 'image/jpeg', alt: 'The shepetal blog. Dictation apps compared. The shepetal wordmark on the dusk afterglow.' }],
  },
  twitter: { card: 'summary_large_image', title, description, images: ['/blog/og/blog.jpg'] },
};

export default function BlogIndex() {
  const rankings = ARTICLES.filter((a) => a.kind === 'ranking');
  const guides = ARTICLES.filter((a) => a.kind === 'guide');
  const comparisons = ARTICLES.filter((a) => a.kind === 'comparison');
  return (
    <main className="bl">
      <header className="bl-wrap bl-head bl-index-head">
        <p className="bl-kicker">The shepetal blog</p>
        <h1 className="bl-title">Dictation apps, compared.</h1>
        <p className="bl-dek">
          The dictation apps people search for, side by side: what they cost, where they run, whether they work offline and where your
          voice goes.
        </p>
      </header>

      <section className="bl-wrap bl-shelf" aria-labelledby="rankings-h">
        <h2 id="rankings-h">Rankings and guides</h2>
        <Cards list={[...rankings, ...guides]} large />
      </section>

      <section className="bl-wrap bl-shelf" aria-labelledby="vs-h">
        <h2 id="vs-h">Wispr Flow, compared</h2>
        <Cards list={comparisons} />
      </section>

      <BlogCta />

      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: ldJson(blogJsonLd(ARTICLES)) }} />
    </main>
  );
}
