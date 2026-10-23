import Link from 'next/link';
import { SiteHeader } from '@/components/site/Shell';
import { ROWS, SHEPETAL, TRY, formatDate, sourceLabel, type Fact, type Pick } from '@/lib/compare';
import { APPS, ARTICLES, BLOG, article, articleJsonLd, blogJsonLd, blogPath, blogRef, factsOfArticle, type Article, type Para } from '@/lib/blog';
import { jsonLd } from '@/lib/seo';

/** A text from src/lib/blog.ts: each "\n" starts a line of its own, so an approved claim stands alone. */
function Lines({ text }: { text: string }) {
  const lines = text.split('\n');
  if (lines.length === 1) return <>{text}</>;
  return (
    <>
      {lines.map((l) => (
        <span key={l} className="s-cmp-line">
          {l}
        </span>
      ))}
    </>
  );
}

/** The trial button: the install guide, which starts the download. ?ref= tells /download which page sent the visitor. */
function TryButton({ refName }: { refName: string }) {
  return (
    <a className="s-btn s-btn-signal" href={`/install?ref=${refName}`}>
      {TRY}
    </a>
  );
}

/** Where a fact comes from: the other app's own page, and the day it was read. */
function Source({ sources, asOf }: { sources: string[]; asOf: string }) {
  return (
    <span className="s-cmp-src">
      {sources.map((u) => (
        <a key={u} href={u} rel="nofollow noopener" className="s-cmp-link">
          {sourceLabel(u)}
        </a>
      ))}
      <span className="s-cmp-asof">
        as of <time dateTime={asOf}>{formatDate(asOf)}</time>
      </span>
    </span>
  );
}

function FactCell({ f }: { f?: Fact }) {
  if (!f) return <td>Not on its pages.</td>;
  return (
    <td>
      {f.text} <Source sources={f.sources} asOf={f.asOf} />
    </td>
  );
}

function Paragraph({ p }: { p: Para }) {
  return (
    <p data-sourced={p.sources ? '' : undefined}>
      <Lines text={p.text} />
      {p.sources && p.asOf && (
        <>
          {' '}
          <Source sources={p.sources} asOf={p.asOf} />
        </>
      )}
    </p>
  );
}

function PickList({ title, picks }: { title: string; picks: Pick[] }) {
  return (
    <section>
      <h3>{title}</h3>
      <ul>
        {picks.map((p) => (
          <li key={p.text}>
            <Lines text={p.text} />
            {p.source && p.asOf && (
              <>
                {' '}
                <Source sources={[p.source]} asOf={p.asOf} />
              </>
            )}
          </li>
        ))}
      </ul>
    </section>
  );
}

/** Two other apps or fewer: one row per fact, shepetal and the apps as columns. More: one row per app. */
function Table({ a }: { a: Article }) {
  const apps = a.apps.map((k) => APPS[k]);
  if (apps.length <= 2) {
    const rows = ROWS.filter((r) => a.rows.includes(r.key) && apps.some((x) => x.facts[r.key]));
    return (
      <div className="s-cmp-scroll">
        <table className="s-cmp-table">
          <thead>
            <tr>
              <td />
              <th scope="col">shepetal</th>
              {apps.map((x) => (
                <th key={x.key} scope="col">
                  {x.name}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.key} data-row={r.key}>
                <th scope="row">{r.label}</th>
                <td>
                  <Lines text={SHEPETAL[r.key]} />
                </td>
                {apps.map((x) => (
                  <FactCell key={x.key} f={x.facts[r.key]} />
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    );
  }
  const cols = ROWS.filter((r) => a.rows.includes(r.key));
  return (
    <div className="s-cmp-scroll">
      <table className="s-cmp-table">
        <thead>
          <tr>
            <td />
            {cols.map((r) => (
              <th key={r.key} scope="col">
                {r.label}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          <tr>
            <th scope="row">shepetal</th>
            {cols.map((r) => (
              <td key={r.key}>
                <Lines text={SHEPETAL[r.key]} />
              </td>
            ))}
          </tr>
          {apps.map((x) => (
            <tr key={x.key} data-row={x.key}>
              <th scope="row">
                {x.compare ? (
                  <Link href={x.compare} prefetch={false}>
                    {x.name}
                  </Link>
                ) : (
                  x.name
                )}
              </th>
              {cols.map((r) => (
                <FactCell key={r.key} f={x.facts[r.key]} />
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** Every fact about another app on the page again, with the full address of its source and the day it was checked. */
function SourceList({ a }: { a: Article }) {
  const link = (u: string) => (
    <span key={u}>
      <a href={u} rel="nofollow noopener">
        {u}
      </a>
      ,{' '}
    </span>
  );
  const paras = a.sections.flatMap((s) => s.paras).filter((p) => p.sources && p.asOf);
  const picks = a.picks.flatMap((g) => g.picks).filter((p) => p.source && p.asOf);
  return (
    <section className="s-cmp-sources" aria-labelledby="s-cmp-sources">
      <h2 id="s-cmp-sources">Sources</h2>
      {factsOfArticle(a).map(({ app, facts }) => (
        <ul key={app.key} data-sources={app.key}>
          {facts.map((f) => (
            <li key={f.key} data-fact={f.key}>
              {app.name}, {f.label}: {f.text} {f.sources.map(link)}
              checked <time dateTime={f.asOf}>{formatDate(f.asOf)}</time>.
            </li>
          ))}
        </ul>
      ))}
      {(paras.length > 0 || picks.length > 0) && (
        <ul data-sources="text">
          {paras.map((p) => (
            <li key={p.text}>
              {p.text} {p.sources!.map(link)}
              checked <time dateTime={p.asOf}>{formatDate(p.asOf!)}</time>.
            </li>
          ))}
          {picks.map((p) => (
            <li key={p.text}>
              {p.text} {link(p.source!)}
              checked <time dateTime={p.asOf}>{formatDate(p.asOf!)}</time>.
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

/** The price, the trial and the button again, as on the use-case and comparison pages. */
function Try({ refName }: { refName: string }) {
  return (
    <section className="s-for-try" aria-labelledby="s-for-try">
      <h2 id="s-for-try" className="s-h2">
        30 days free
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
        <TryButton refName={refName} />
      </div>
      <p className="s-small s-for-more">
        If you have more questions, the <Link href="/faq" prefetch={false}>FAQ</Link> and the <Link href="/privacy" prefetch={false}>Privacy Policy</Link> answer them.
      </p>
    </section>
  );
}

/** The blog's index (/blog): every article, newest first as listed in src/lib/blog.ts. */
export function BlogIndexPage() {
  const ref = blogRef();
  return (
    <>
      <SiteHeader end={<Link href="/account" prefetch={false}>Account</Link>} />
      <main className="s-main s-legal s-for s-cmp s-blog">
        <h1 className="s-h2">{BLOG.h1}</h1>
        <p className="s-lede">{BLOG.lede}</p>
        <div className="s-actions s-for-cta">
          <TryButton refName={ref} />
        </div>
        <ul className="s-blog-list">
          {ARTICLES.map((a) => (
            <li key={a.slug}>
              <h2 className="s-blog-title">
                <Link href={blogPath(a.slug)} prefetch={false}>
                  {a.h1}
                </Link>
              </h2>
              <p>{a.description}</p>
              <p className="s-mono">
                Updated <time dateTime={a.updated}>{formatDate(a.updated)}</time>
              </p>
            </li>
          ))}
        </ul>
        <Try refName={ref} />
      </main>
      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: jsonLd(blogJsonLd()) }} />
    </>
  );
}

/** An article (/blog/<slug>, src/lib/blog.ts): static, in the comparison pages' style. */
export function BlogArticlePage({ slug }: { slug: string }) {
  const a = article(slug);
  const ref = blogRef(slug);
  return (
    <>
      <SiteHeader end={<Link href="/blog" prefetch={false}>Blog</Link>} />
      <main className="s-main s-legal s-for s-cmp s-blog">
        <h1 className="s-h2">{a.h1}</h1>
        <p className="s-lede">{a.lede}</p>
        <p className="s-mono">
          Updated <time dateTime={a.updated}>{formatDate(a.updated)}</time>
        </p>
        <div className="s-actions s-for-cta">
          <TryButton refName={ref} />
        </div>

        <div className="s-prose">
          <h2>Side by side</h2>
          <Table a={a} />
          <p className="s-cmp-note">
            Every line on another app here comes from its own pages, and each one links the page and the day we checked it. shepetal is independent of these apps and of the companies that make them.
          </p>

          {a.sections.map((s) => (
            <section key={s.title}>
              <h2>{s.title}</h2>
              {s.paras.map((p) => (
                <Paragraph key={p.text} p={p} />
              ))}
            </section>
          ))}

          <h2>Which to pick</h2>
          {a.picks.map((g) => (
            <PickList key={g.app} title={`Pick ${APPS[g.app].name} if`} picks={g.picks} />
          ))}
          <PickList title="Pick shepetal if" picks={a.pickShepetal} />

          <h2>Read next</h2>
          <ul>
            {a.next.map((n) => (
              <li key={n.href}>
                <Link href={n.href} prefetch={false}>
                  {n.label}
                </Link>
              </li>
            ))}
          </ul>

          <SourceList a={a} />
        </div>

        <Try refName={ref} />
      </main>
      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: jsonLd(articleJsonLd(a)) }} />
    </>
  );
}
