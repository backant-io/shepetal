import { attribution, attributionQuery } from './analytics';

/**
 * What worker.ts adds to an HTML page at the edge, so the pages themselves stay static (served as they were built):
 * on /install, the meta refresh that starts the download, carrying where the visitor came from (?ref=, utm_*) on to
 * /download, where the download counts it, and the same on the fallback link. Added here, never by React: a refresh
 * in the page's RSC payload made React insert its own bare one on hydration, and Chrome followed that. Every other
 * page is served as built (page views are counted on the server: src/lib/server-analytics.ts).
 * The ETag goes with any change: it was computed over the page as built.
 */
export function withEdgeHtml(res: Response, url: URL): Response {
  if (url.pathname !== '/install' || !(res.headers.get('content-type') ?? '').startsWith('text/html')) return res;
  const q = attributionQuery(attribution(url.searchParams));
  const html = new HTMLRewriter();
  // attribution() lets only [\w.+-] through, so q needs no escaping.
  html.on('head', { element: (head) => void head.append(`<meta http-equiv="refresh" content="1;url=/download${q}">`, { html: true }) });
  if (q) html.on('a[href="/download"]', { element: (a) => void a.setAttribute('href', `/download${q}`) });
  const out = html.transform(res);
  out.headers.delete('etag');
  return out;
}
