import Link from 'next/link';
import { SiteHeader } from '@/components/site/Shell';
import {
  COMPARISONS,
  ROWS,
  SHEPETAL,
  TRY,
  comparePath,
  compareRef,
  comparison,
  factsOf,
  formatDate,
  guide,
  sourceLabel,
  type Comparison,
  type Fact,
  type Pick,
} from '@/lib/compare';

/** A text from src/lib/compare.ts: each "\n" starts a line of its own, so an approved claim stands alone. */
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

function FactCell({ f }: { f: Fact }) {
  return (
    <td>
      {f.text} <Source sources={f.sources} asOf={f.asOf} />
    </td>
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

/** Every fact about another app again, with the full address of its source and the day it was checked. */
function SourceList({ apps }: { apps: Comparison[] }) {
  return (
    <section className="s-cmp-sources" aria-labelledby="s-cmp-sources">
      <h2 id="s-cmp-sources">Sources</h2>
      {apps.map((c) => (
        <ul key={c.slug} data-sources={c.slug}>
          {factsOf(c).map((f) => (
            <li key={f.key} data-fact={f.key}>
              {apps.length > 1 ? `${c.name}, ` : ''}
              {f.label}: {f.text}{' '}
              {f.sources.map((u) => (
                <span key={u}>
                  <a href={u} rel="nofollow noopener">
                    {u}
                  </a>
                  ,{' '}
                </span>
              ))}
              checked <time dateTime={f.asOf}>{formatDate(f.asOf)}</time>.
            </li>
          ))}
        </ul>
      ))}
    </section>
  );
}

/** The price, the trial and the button again, as on the use-case pages. */
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

/** A comparison page (/compare/<slug>, src/lib/compare.ts): static, in the site's page style. */
export function ComparePage({ slug }: { slug: string }) {
  const c = comparison(slug);
  const ref = compareRef(slug);
  return (
    <>
      <SiteHeader end={<Link href="/account" prefetch={false}>Account</Link>} />
      <main className="s-main s-legal s-for s-cmp">
        <h1 className="s-h2">{c.h1}</h1>
        <p className="s-lede">
          <Lines text={c.lede} />
        </p>
        <div className="s-actions s-for-cta">
          <TryButton refName={ref} />
        </div>

        <div className="s-prose">
          <h2>Side by side</h2>
          <div className="s-cmp-scroll">
            <table className="s-cmp-table">
              <thead>
                <tr>
                  <td />
                  <th scope="col">shepetal</th>
                  <th scope="col">{c.name}</th>
                </tr>
              </thead>
              <tbody>
                {ROWS.map((r) => {
                  const f = c.facts[r.key];
                  return (
                    f && (
                      <tr key={r.key} data-row={r.key}>
                        <th scope="row">{r.label}</th>
                        <td>
                          <Lines text={SHEPETAL[r.key]} />
                        </td>
                        <FactCell f={f} />
                      </tr>
                    )
                  );
                })}
              </tbody>
            </table>
          </div>
          <p className="s-cmp-note">
            Every line on {c.name} here comes from its own pages, and each one links the page and the day we checked it. shepetal is independent of {c.name} and of the company that makes it.
          </p>

          <h2>Which to pick</h2>
          <PickList title={`Pick ${c.name} if`} picks={c.pickOther} />
          <PickList title="Pick shepetal if" picks={c.pickShepetal} />

          <SourceList apps={[c]} />
        </div>

        <Try refName={ref} />
      </main>
    </>
  );
}

/** A search guide (/offline-dictation-mac, /private-dictation-mac): shepetal's answer, then the four apps' facts. */
export function GuidePage({ slug }: { slug: string }) {
  const g = guide(slug);
  const cols = ROWS.filter((r) => g.columns.includes(r.key));
  return (
    <>
      <SiteHeader end={<Link href="/account" prefetch={false}>Account</Link>} />
      <main className="s-main s-legal s-for s-cmp">
        <h1 className="s-h2">{g.h1}</h1>
        <p className="s-lede">
          <Lines text={g.lede} />
        </p>
        <div className="s-actions s-for-cta">
          <TryButton refName={g.ref} />
        </div>

        <div className="s-prose">
          {g.sections.map((s) => (
            <section key={s.title}>
              <h2>{s.title}</h2>
              <p>
                <Lines text={s.text} />
              </p>
            </section>
          ))}

          <h2>Side by side</h2>
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
                {COMPARISONS.map((c) => (
                  <tr key={c.slug} data-row={c.slug}>
                    <th scope="row">
                      <Link href={comparePath(c.slug)} prefetch={false}>{c.name}</Link>
                    </th>
                    {cols.map((r) => {
                      const f = c.facts[r.key];
                      return f ? <FactCell key={r.key} f={f} /> : <td key={r.key}>Not on its pages.</td>;
                    })}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="s-cmp-note">
            Every line on the other apps here comes from their own pages, and each one links the page and the day we checked it. shepetal is independent of all of them.
          </p>

          <h2>Which to pick</h2>
          <p>{g.others}</p>
          <p>Pick shepetal if you want every dictation processed on your Mac, which is the only way shepetal works.</p>

          <SourceList apps={COMPARISONS} />
        </div>

        <Try refName={g.ref} />
      </main>
    </>
  );
}
