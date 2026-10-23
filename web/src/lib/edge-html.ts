import { attribution, attributionQuery } from './analytics';
import { safeNext } from './next-path';

/**
 * What worker.ts adds to an HTML page at the edge, so the pages themselves stay static (served as they were built):
 * - on /install, the inline script that starts the download about 1 s after the page shows (location.replace),
 *   carrying where the visitor came from (?ref=, utm_*) on to /download, where the download counts it, and the same on
 *   the fallback link, which is what a visitor without JavaScript follows. A script, not a timed meta refresh, which
 *   fails axe's meta-refresh rule (Lighthouse accessibility). The CSP's script-src allows inline scripts
 *   (security-headers.mjs). Added here, never by React: a refresh in the page's RSC payload made React insert its own
 *   bare one on hydration, and Chrome followed that;
 * - on /login, where the sign-in form returns to (?next=, checked) and the failed line on ?error=. Attributes only:
 *   hydration keeps them, while an element added or changed by hand would be dropped;
 * - on /changelog, the release list (`releases`, lib/changelog.ts releasesHtml) in its container;
 * - on /waitlist/unsubscribe, the signed ?t= of the link in the page's static form;
 * - /login and /account depend on the visitor's cookie (worker.ts redirects first), so no cache may keep them.
 * Every other page is served as built (page views are counted on the server: src/lib/server-analytics.ts).
 * The ETag goes with any change: it was computed over the page as built.
 */
export function withEdgeHtml(res: Response, url: URL, releases?: string): Response {
  if (!(res.headers.get('content-type') ?? '').startsWith('text/html')) return res;
  const install = url.pathname === '/install';
  const login = url.pathname === '/login';
  const personal = login || url.pathname === '/account';
  // A signed link is base64url and a dot, so it needs no escaping either.
  const t = url.pathname === '/waitlist/unsubscribe' ? url.searchParams.get('t')?.match(/^[\w-]{1,1000}\.[\w-]{43}$/)?.[0] : undefined;
  if (!install && !personal && !t && releases === undefined) return res;
  const html = new HTMLRewriter();
  if (install) {
    const q = attributionQuery(attribution(url.searchParams));
    // attribution() lets only [\w.+-] through, so q needs no escaping, in the script or in the link.
    html.on('head', { element: (head) => void head.append(downloadStarter(q), { html: true }) });
    if (q) html.on('a[href="/download"]', { element: (a) => void a.setAttribute('href', `/download${q}`) });
  }
  if (login) {
    const back = `/api/auth/signin/google?callbackUrl=${encodeURIComponent(safeNext(url.searchParams.get('next')))}`;
    html.on('form[action^="/api/auth/signin/google"]', { element: (form) => void form.setAttribute('action', back) });
    if (url.searchParams.get('error')) html.on('p[role="alert"][hidden]', { element: (p) => void p.removeAttribute('hidden') });
  }
  if (releases !== undefined) html.on('[data-releases]', { element: (list) => void list.setInnerContent(releases, { html: true }) });
  if (t) html.on('input[name="t"]', { element: (input) => void input.setAttribute('value', t) });
  const out = html.transform(res);
  out.headers.delete('etag');
  if (personal) out.headers.set('cache-control', 'private, no-store');
  if (releases !== undefined) out.headers.set('cache-control', 'no-store');
  return out;
}

/** The script on /install that starts the download: /download with the attribution, 1 s after the page has loaded. */
export const downloadStarter = (q: string) =>
  `<script>addEventListener("DOMContentLoaded",function(){setTimeout(function(){location.replace("/download${q}")},1000)})</script>`;
