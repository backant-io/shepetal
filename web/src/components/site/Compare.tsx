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
  formatDate,
  guide,
  sourceLabel,
  type Fact,
  type Pick,
} from '@/lib/compare';

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
            {p.text}
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

/** The price, the trial and the button again, as on the use-case pages. */
function Try({ refName }: { refName: string }) {
  return (
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
        <TryButton refName={refName} />
      </div>
      <p className="s-small s-for-more">
        More in the <Link href="/faq">FAQ</Link> and the <Link href="/privacy">Privacy Policy</Link>.
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
        <p className="s-lede">{c.lede}</p>
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
                {ROWS.map((r) => (
                  <tr key={r.key} data-row={r.key}>
                    <th scope="row">{r.label}</th>
                    <td>{SHEPETAL[r.key]}</td>
                    <FactCell f={c.facts[r.key]} />
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="s-cmp-note">
            What {c.name} offers, in the words of its own pages, linked. shepetal is not affiliated with {c.name}.
          </p>

          <h2>When to pick which</h2>
          <PickList title={`Pick ${c.name} if`} picks={c.pickOther} />
          <PickList title="Pick shepetal if" picks={c.pickShepetal} />
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
        <p className="s-lede">{g.lede}</p>
        <div className="s-actions s-for-cta">
          <TryButton refName={g.ref} />
        </div>

        <div className="s-prose">
          {g.sections.map((s) => (
            <section key={s.title}>
              <h2>{s.title}</h2>
              <p>{s.text}</p>
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
                    <td key={r.key}>{SHEPETAL[r.key]}</td>
                  ))}
                </tr>
                {COMPARISONS.map((c) => (
                  <tr key={c.slug} data-row={c.slug}>
                    <th scope="row">
                      <Link href={comparePath(c.slug)}>{c.name}</Link>
                    </th>
                    {cols.map((r) => (
                      <FactCell key={r.key} f={c.facts[r.key]} />
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="s-cmp-note">What each app offers, in the words of its own pages, linked. shepetal is not affiliated with any of them.</p>

          <h2>When to pick which</h2>
          <p>{g.others}</p>
          <p>Pick shepetal if you want on-device processing and nothing else. shepetal has no cloud processing.</p>
        </div>

        <Try refName={g.ref} />
      </main>
    </>
  );
}
