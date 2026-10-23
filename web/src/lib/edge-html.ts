import { attribution, attributionQuery } from './analytics';

/**
 * What worker.ts adds to an HTML page at the edge, so the pages themselves stay static (served as they were built):
 * on /install, the inline script that starts the download about 1 s after the page shows (location.replace),
 * carrying where the visitor came from (?ref=, utm_*) on to /download, where the download counts it, and the same on
 * the fallback link, which is what a visitor without JavaScript follows. A script, not a timed meta refresh, which
 * fails axe's meta-refresh rule (Lighthouse accessibility). The CSP's script-src allows inline scripts
 * (security-headers.mjs). Added here, never by React: a refresh in the page's RSC payload made React insert its own
 * bare one on hydration, and Chrome followed that. Every other page is served as built (page views are counted on
 * the server: src/lib/server-analytics.ts).
 * The ETag goes with any change: it was computed over the page as built.
 */
export function withEdgeHtml(res: Response, url: URL): Response {
  if (url.pathname !== '/install' || !(res.headers.get('content-type') ?? '').startsWith('text/html')) return res;
  const q = attributionQuery(attribution(url.searchParams));
  const html = new HTMLRewriter();
  // attribution() lets only [\w.+-] through, so q needs no escaping, in the script or in the link.
  html.on('head', { element: (head) => void head.append(downloadStarter(q), { html: true }) });
  if (q) html.on('a[href="/download"]', { element: (a) => void a.setAttribute('href', `/download${q}`) });
  const out = html.transform(res);
  out.headers.delete('etag');
  return out;
}

/** The script on /install that starts the download: /download with the attribution, 1 s after the page has loaded. */
export const downloadStarter = (q: string) =>
  `<script>addEventListener("DOMContentLoaded",function(){setTimeout(function(){location.replace("/download${q}")},1000)})</script>`;
