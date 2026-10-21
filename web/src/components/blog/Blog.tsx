import Link from 'next/link';
import type { ReactNode } from 'react';
import { APPS } from '../../lib/blog/apps';
import type { AppId, App } from '../../lib/blog/types';

/** The first mention of an app in an article's text: a link to the app's own site. Once per app per article. */
export function AppLink({ id, children }: { id: AppId; children?: ReactNode }) {
  const app = APPS[id];
  return (
    <a href={app.url} rel="noopener" className="bl-ext">
      {children ?? app.name}
    </a>
  );
}

/** A link to another article on the blog. */
export function ToArticle({ slug, children }: { slug: string; children: ReactNode }) {
  return <Link href={`/blog/${slug}`}>{children}</Link>;
}

type Row = { key: keyof App; label: string };

export const ROWS: Row[] = [
  { key: 'price', label: 'Price' },
  { key: 'free', label: 'Free to try' },
  { key: 'platforms', label: 'Platforms' },
  { key: 'recognition', label: 'Speech recognition' },
  { key: 'offline', label: 'Offline' },
  { key: 'privacy', label: 'Your voice and text' },
  { key: 'everyApp', label: 'Works in' },
  { key: 'meetings', label: 'Meetings' },
];

/** The side-by-side table. On a phone each app becomes a card (CSS), so nothing scrolls sideways. */
export function Compare({ ids, rows = ROWS, caption }: { ids: AppId[]; rows?: Row[]; caption: string }) {
  const apps = ids.map((id) => APPS[id]);
  return (
    <div className="bl-table-wrap">
      <table className="bl-table" data-cols={apps.length}>
        <caption>{caption}</caption>
        <thead>
          <tr>
            <td />
            {apps.map((a) => (
              <th key={a.id} scope="col" data-us={a.id === 'shepetal' || undefined}>
                {a.name}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.key}>
              <th scope="row">{r.label}</th>
              {apps.map((a) => (
                <td key={a.id} data-label={a.name} data-us={a.id === 'shepetal' || undefined}>
                  {a[r.key]}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** "Pick X if…": the honest verdict, one card per app. */
export function Picks({ picks }: { picks: { id: AppId; why: ReactNode }[] }) {
  return (
    <ul className="bl-picks">
      {picks.map((p) => (
        <li key={p.id} data-us={p.id === 'shepetal' || undefined}>
          <p className="bl-picks-h">Pick {APPS[p.id].name} if</p>
          <p>{p.why}</p>
        </li>
      ))}
    </ul>
  );
}

/** One entry of a ranked list: the rank, the name as an h3, the facts in a short list, then the text. */
export function Ranked({ rank, id, verdict, children }: { rank: number; id: AppId; verdict: string; children: ReactNode }) {
  const a = APPS[id];
  return (
    <article className="bl-rank" id={`${rank}-${id}`} data-us={id === 'shepetal' || undefined}>
      <h3>
        <span className="bl-rank-n" aria-hidden="true">
          {rank}
        </span>
        <span className="sr">{rank}. </span>
        {a.name}
        <span className="bl-rank-v">{verdict}</span>
      </h3>
      <dl className="bl-facts">
        <div>
          <dt>Price</dt>
          <dd>{a.price}</dd>
        </div>
        <div>
          <dt>Speech recognition</dt>
          <dd>{a.recognition}</dd>
        </div>
        <div>
          <dt>Offline</dt>
          <dd>{a.offline}</dd>
        </div>
        <div>
          <dt>Platforms</dt>
          <dd>{a.platforms}</dd>
        </div>
      </dl>
      <div className="bl-rank-body">{children}</div>
    </article>
  );
}

/** Many apps at a glance: one row per app, a few facts as columns. On a phone each row becomes a card. */
export function AppTable({ ids, cols, caption }: { ids: AppId[]; cols: Row[]; caption: string }) {
  return (
    <div className="bl-table-wrap">
      <table className="bl-table bl-table-rows">
        <caption>{caption}</caption>
        <thead>
          <tr>
            <th scope="col">App</th>
            {cols.map((c) => (
              <th key={c.key} scope="col">
                {c.label}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {ids.map((id) => {
            const a = APPS[id];
            return (
              <tr key={id} data-us={id === 'shepetal' || undefined}>
                <th scope="row">{a.name}</th>
                {cols.map((c) => (
                  <td key={c.key} data-label={c.label}>
                    {a[c.key]}
                  </td>
                ))}
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

export const GLANCE: Row[] = [
  { key: 'price', label: 'Price' },
  { key: 'recognition', label: 'Speech recognition' },
  { key: 'offline', label: 'Offline' },
  { key: 'platforms', label: 'Platforms' },
];
