import { attribution, attributionQuery } from './analytics';
import { analyticsConfig } from './analytics-config';

/**
 * What worker.ts adds to an HTML page at the edge, so the pages themselves stay static (served as they were built):
 * - with POSTHOG_KEY set (a secret, set at GO), <meta name="shepetal-analytics"> with the key and host, which
 *   src/components/Analytics.tsx reads. Without it no analytics code ever loads, and the key is never in the build;
 * - on /install, the meta refresh that starts the download, carrying where the visitor came from (?ref=, utm_*) on to
 *   /download, where the download counts it, and the same on the fallback link. Added here, never by React: a
 *   refresh in the page's RSC payload made React insert its own bare one on hydration, and Chrome followed that.
 * The ETag goes with any change: it was computed over the page as built.
 */
export function withEdgeHtml(res: Response, env: { POSTHOG_KEY?: string; POSTHOG_HOST?: string }, url: URL): Response {
  if (!(res.headers.get('content-type') ?? '').startsWith('text/html')) return res;
  const { key, host } = analyticsConfig(env);
  const q = url.pathname === '/install' ? attributionQuery(attribution(url.searchParams)) : '';
  const install = url.pathname === '/install';
  if (!key && !install) return res;
  const html = new HTMLRewriter();
  if (key) {
    const content = JSON.stringify({ key, host }).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
    html.on('head', { element: (head) => void head.append(`<meta name="shepetal-analytics" content="${content}">`, { html: true }) });
  }
  if (install) {
    // attribution() lets only [\w.+-] through, so q needs no escaping.
    html.on('head', { element: (head) => void head.append(`<meta http-equiv="refresh" content="1;url=/download${q}">`, { html: true }) });
    if (q) html.on('a[href="/download"]', { element: (a) => void a.setAttribute('href', `/download${q}`) });
  }
  const out = html.transform(res);
  out.headers.delete('etag');
  return out;
}
