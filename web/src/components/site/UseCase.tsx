import Link from 'next/link';
import { SiteHeader } from '@/components/site/Shell';
import { jsonLd } from '@/lib/seo';
import { TRY, useCase, useCaseFaqJsonLd } from '@/lib/use-cases';

/** The trial button: the install guide, which starts the download. ?ref= tells /download which page sent the visitor. */
function TryButton({ slug }: { slug: string }) {
  return (
    <a className="s-btn s-btn-signal" href={`/install?ref=for-${slug}`}>
      {TRY}
    </a>
  );
}

/** A use-case page (/for/<slug>, src/lib/use-cases.ts): static, in the site's page style. */
export function UseCasePage({ slug }: { slug: string }) {
  const u = useCase(slug);
  const faq = useCaseFaqJsonLd(slug);
  return (
    <>
      <SiteHeader end={<Link href="/account" prefetch={false}>Account</Link>} />
      <main className="s-main s-legal s-for">
        <h1 className="s-h2">{u.h1}</h1>
        <p className="s-lede">{u.lede}</p>
        <div className="s-actions s-for-cta">
          <TryButton slug={slug} />
        </div>

        <div className="s-prose">
          {u.scenarios.map((s) => (
            <section key={s.title}>
              <h2>{s.title}</h2>
              <p>{s.text}</p>
            </section>
          ))}
          {u.note && <p className="s-for-note">{u.note}</p>}

          <h2>The facts</h2>
          <ul>
            {u.facts.map((f) => (
              <li key={f}>{f}</li>
            ))}
            <li>macOS 14.4 or later on Apple silicon.</li>
            <li>25 European languages.</li>
          </ul>

          {u.qas?.map((x) => (
            <section key={x.q}>
              <h2>{x.q}</h2>
              <p>{x.a}</p>
            </section>
          ))}
        </div>

        <section className="s-for-try" aria-labelledby="s-for-try">
          <h2 id="s-for-try" className="s-h2">
            30 days free.
          </h2>
          <div className="s-plans">
            <div className="s-plan">
              <p className="s-price">$23.99</p>
              <p className="s-price-line">once. Yours forever.</p>
            </div>
            <div className="s-plan">
              <p className="s-price">$0.99</p>
              <p className="s-price-line">a month.</p>
            </div>
          </div>
          <div className="s-actions s-for-cta">
            <TryButton slug={slug} />
          </div>
          <p className="s-small s-for-more">
            More in the <Link href="/faq">FAQ</Link> and the <Link href="/privacy">Privacy Policy</Link>.
          </p>
        </section>
        {faq && <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: jsonLd(faq) }} />}
      </main>
    </>
  );
}
