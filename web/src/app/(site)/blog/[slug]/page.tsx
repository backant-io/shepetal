import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ARTICLES, bySlug, KIND_LABEL } from '@/lib/blog/articles';
import { articleJsonLd, AUTHOR, ldJson, ogImageFor } from '@/lib/blog/seo';
import { BlogCta, Cards, formatDate } from '@/components/blog/parts';

// Every article is prerendered at build time. dynamicParams stays on: on the Worker, OpenNext without an incremental
// cache answers a prerendered page with NoFallbackError (a 404) when dynamicParams is false. An unknown slug is a 404
// through notFound() below.

export function generateStaticParams() {
  return ARTICLES.map((a) => ({ slug: a.slug }));
}

type Props = { params: Promise<{ slug: string }> };

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const a = bySlug((await params).slug);
  if (!a) return {};
  const url = `/blog/${a.slug}`;
  const image = ogImageFor(a);
  return {
    title: { absolute: a.seoTitle },
    description: a.description,
    keywords: [a.keyword],
    authors: [{ name: AUTHOR.name }],
    alternates: { canonical: url },
    openGraph: {
      type: 'article',
      url,
      title: a.title,
      description: a.description,
      siteName: 'shepetal',
      locale: 'en_US',
      publishedTime: a.published,
      modifiedTime: a.updated,
      authors: [AUTHOR.name],
      images: [image],
    },
    twitter: { card: 'summary_large_image', title: a.title, description: a.description, images: [image] },
  };
}

export default async function ArticlePage({ params }: Props) {
  const a = bySlug((await params).slug);
  if (!a) notFound();
  const related = a.related.map((s) => bySlug(s)).filter((r) => r !== undefined);
  const toc = [...a.sections.map((s) => ({ id: s.id, title: s.title })), ...(a.faq.length ? [{ id: 'questions', title: 'Questions' }] : [])];

  return (
    <main className="bl">
      <article className="bl-article">
        <header className="bl-wrap bl-head">
          <nav aria-label="Breadcrumb" className="bl-crumbs">
            <ol>
              <li>
                <Link href="/">shepetal</Link>
              </li>
              <li>
                <Link href="/blog">Blog</Link>
              </li>
              <li aria-current="page">{KIND_LABEL[a.kind]}</li>
            </ol>
          </nav>
          <h1 className="bl-title">{a.title}</h1>
          <p className="bl-dek">{a.dek}</p>
          <p className="bl-byline">
            By {AUTHOR.name}, {AUTHOR.role} · Updated <time dateTime={a.updated}>{formatDate(a.updated)}</time>
          </p>
        </header>

        <div className="bl-wrap bl-grid">
          <nav className="bl-toc" aria-labelledby="toc-h">
            <p id="toc-h" className="bl-toc-h">
              On this page
            </p>
            <ol>
              {toc.map((t) => (
                <li key={t.id}>
                  <a href={`#${t.id}`}>{t.title}</a>
                </li>
              ))}
            </ol>
          </nav>

          <div className="bl-body">
            <section className="bl-short" aria-labelledby="short-h">
              <h2 id="short-h">The short answer</h2>
              {a.short}
            </section>

            {a.sections.map((s) => (
              <section key={s.id} id={s.id} aria-labelledby={`${s.id}-h`}>
                <h2 id={`${s.id}-h`}>{s.title}</h2>
                {s.body}
              </section>
            ))}

            {a.faq.length > 0 && (
              <section id="questions" aria-labelledby="questions-h" className="bl-faq">
                <h2 id="questions-h">Questions</h2>
                {a.faq.map((f) => (
                  <div key={f.q}>
                    <h3>{f.q}</h3>
                    <p>{f.a}</p>
                  </div>
                ))}
              </section>
            )}
          </div>
        </div>
      </article>

      <BlogCta />

      {related.length > 0 && (
        <section className="bl-wrap bl-related" aria-labelledby="related-h">
          <h2 id="related-h">Read next</h2>
          <Cards list={related} />
        </section>
      )}

      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: ldJson(articleJsonLd(a)) }} />
    </main>
  );
}
