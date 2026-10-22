import { getCloudflareContext } from '@opennextjs/cloudflare';

// The Mac releases live in the R2 bucket shepetal-releases (binding RELEASES), served from this site only:
//   staging/<v>/…   CI uploads, never served
//   releases/<v>/…  written once by scripts/mac/promote.sh, served as /download/<v>/<file>
//   latest.json     {"version":"0.2.0","build":745}: LATEST, written only by promote.sh --latest (Pavel's GO)

/** The R2 bucket shepetal-releases. Call inside a request. */
export const releases = () => getCloudflareContext().env.RELEASES;

const VERSION = /^\d+\.\d+\.\d+$/;
export const FILES = (v: string) => [`Shepetal-${v}.dmg`, `Shepetal-${v}.dmg.sha256`, 'appcast.xml'];

/** The version latest.json names, or null before the first promotion. Anything else in it throws (a 500). */
export async function latest(b: R2Bucket): Promise<string | null> {
  const o = await b.get('latest.json');
  if (!o) return null;
  const { version } = await o.json<{ version?: unknown }>();
  if (typeof version !== 'string' || !VERSION.test(version)) throw new Error(`latest.json: bad version ${JSON.stringify(version)}`);
  return version;
}

const notFound = () => new Response('Not found', { status: 404, headers: { 'content-type': 'text/plain' } });

/** The single byte range a Range header asks for, clamped to size; null to serve it whole (no header, or not one
 * bytes range: RFC 9110 14.2 lets a server ignore it); 416 when it starts past the end. */
function byteRange(h: string | null, size: number): [number, number] | null | 416 {
  const m = h?.match(/^bytes=(\d*)-(\d*)$/);
  if (!m || (!m[1] && !m[2]) || (m[1] && m[2] && +m[2] < +m[1])) return null;
  const start = m[1] ? +m[1] : Math.max(0, size - +m[2]);
  const end = m[1] && m[2] ? Math.min(+m[2], size - 1) : size - 1;
  return start >= size || end < start ? 416 : [start, end];
}

/** An R2 object as a response, with Range support so a broken download resumes. The range is resolved here (one head
 * for its size) rather than handed to R2 as a header: local R2 serves an unsatisfiable header range whole. */
export async function serve(b: R2Bucket, key: string, req: Request, cacheControl: string): Promise<Response> {
  const header = req.headers.get('range');
  const head = header ? await b.head(key) : null;
  const r = head && byteRange(header, head.size);
  if (r === 416) return new Response(null, { status: 416, headers: { 'content-range': `bytes */${head!.size}` } });
  const o = await b.get(key, r ? { range: { offset: r[0], length: r[1] - r[0] + 1 } } : undefined);
  if (!o) return notFound();
  const headers = new Headers();
  o.writeHttpMetadata(headers);
  headers.set('etag', o.httpEtag);
  headers.set('accept-ranges', 'bytes');
  headers.set('cache-control', cacheControl);
  // The Next layer streams the body chunked; the length lets a browser show the download's size and progress.
  headers.set('content-length', String(r ? r[1] - r[0] + 1 : o.size));
  if (!r) return new Response(o.body, { headers });
  headers.set('content-range', `bytes ${r[0]}-${r[1]}/${o.size}`);
  return new Response(o.body, { status: 206, headers });
}

const COMING_SOON = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>shepetal for Mac is coming soon</title></head>
<body style="font-family:system-ui,sans-serif;max-width:32rem;margin:6rem auto;padding:0 1rem;line-height:1.5">
<h1>shepetal for Mac is coming soon</h1>
<p>The installer is not out yet. It will be here as soon as it is ready.</p>
<p><a href="/">Back to shepetal</a></p></body></html>`;

/** GET /download, open to everyone (sign-in happens in the app): 302 to LATEST's DMG, or coming soon. */
export async function download(b: R2Bucket): Promise<Response> {
  const v = await latest(b);
  if (!v) return new Response(COMING_SOON, { headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-cache' } });
  // Relative, so the Worker needs no domain: the browser stays on the host it asked.
  return new Response(null, { status: 302, headers: { location: `/download/${v}/Shepetal-${v}.dmg`, 'cache-control': 'public, max-age=300' } });
}

/** GET /download/<v>/<file>: releases/<v>/<file>. Keys are written once, so a year, immutable (and If-Range can be ignored). */
export function file(b: R2Bucket, req: Request, v: string, name: string): Promise<Response> | Response {
  if (!VERSION.test(v) || !FILES(v).includes(name)) return notFound();
  return serve(b, `releases/${v}/${name}`, req, 'public, max-age=31536000, immutable');
}

const EMPTY_FEED = '<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel/></rss>\n';

/** GET /appcast.xml, the Sparkle feed the app checks: LATEST's appcast passed through (one request, one origin), or an
 * empty feed before the first promotion. */
export async function appcast(b: R2Bucket, req: Request): Promise<Response> {
  const v = await latest(b);
  if (!v) return new Response(EMPTY_FEED, { headers: { 'content-type': 'application/xml; charset=utf-8', 'cache-control': 'no-cache' } });
  const res = await serve(b, `releases/${v}/appcast.xml`, req, 'public, max-age=300');
  if (res.ok) res.headers.set('content-type', 'application/xml; charset=utf-8');
  return res;
}
