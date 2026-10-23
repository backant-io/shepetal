import { attribution, attributionQuery } from './analytics';

/**
 * What worker.ts adds to an HTML page at the edge, so the pages themselves stay static (served as they were built):
 * on /install, the inline script that starts the download about 1 s after the page shows (location.replace),
 * carrying where the visitor came from (?ref=, utm_*) on to /download, where the download counts it, and the same on
 * the fallback link, which is what a visitor without JavaScript follows. A script, not a timed meta refresh, which
 * fails axe's meta-refresh rule (Lighthouse accessibility). The CSP's script-src allows inline scripts
 * (security-headers.mjs). Added here, never by React: a refresh in the page's RSC payload made React insert its own
 * bare one on hydration, and Chrome followed that. Every other page is served as built (page views are counted on
 * the server: src/lib/server-analytics.ts), except /waitlist/unsubscribe, whose static form gets the signed ?t= of the
 * link here.
 * The ETag goes with any change: it was computed over the page as built.
 */
export function withEdgeHtml(res: Response, url: URL): Response {
  if (!(res.headers.get('content-type') ?? '').startsWith('text/html')) return res;
  const install = url.pathname === '/install';
  // A signed link is base64url and a dot, so it needs no escaping either.
  const t = url.pathname === '/waitlist/unsubscribe' ? url.searchParams.get('t')?.match(/^[\w-]{1,1000}\.[\w-]{43}$/)?.[0] : undefined;
  if (!install && !t) return res;
  const html = new HTMLRewriter();
  if (install) {
    const q = attributionQuery(attribution(url.searchParams));
    // attribution() lets only [\w.+-] through, so q needs no escaping, in the script or in the link.
    html.on('head', { element: (head) => void head.append(downloadStarter(q), { html: true }) });
    if (q) html.on('a[href="/download"]', { element: (a) => void a.setAttribute('href', `/download${q}`) });
  }
  if (t) html.on('input[name="t"]', { element: (input) => void input.setAttribute('value', t) });
  const out = html.transform(res);
  out.headers.delete('etag');
  return out;
}

/** The script on /install that starts the download: /download with the attribution, 1 s after the page has loaded. */
export const downloadStarter = (q: string) =>
  `<script>addEventListener("DOMContentLoaded",function(){setTimeout(function(){location.replace("/download${q}")},1000)})</script>`;
