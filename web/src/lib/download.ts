import { siteOrigin } from './site';

/**
 * The Mac app's installer and Sparkle appcast, served from shepetal's own domain. They live in the latest release of
 * the (soon private) repo, but nothing a customer sees points at GitHub: the Worker fetches the asset with
 * GITHUB_TOKEN (a read-only token, a secret) and streams it as https://<SHEPETAL_DOMAIN>/download/<name>.
 */
const REPO = 'backant-io/shepetal';
const API = 'https://api.github.com';

type Asset = { id: number; name: string; size?: number; browser_download_url?: string };
type Release = { assets?: Asset[] };

/** The installer of a release: Shepetal-<version>.dmg (or a .pkg), or null. */
export const installerOf = (r: Release): Asset | null =>
  r.assets?.find((a) => /^Shepetal-[\w.+-]+\.dmg$/.test(a.name)) ?? r.assets?.find((a) => /^Shepetal-[\w.+-]+\.pkg$/.test(a.name)) ?? null;

/** Only these assets are served: the installer, its checksum and the appcast. */
export const servable = (name: string) => /^Shepetal-[\w.+-]+\.(dmg|pkg|dmg\.sha256)$/.test(name) || name === 'appcast.xml';

const headers = (accept: string): HeadersInit => ({
  accept,
  'user-agent': 'shepetal-web',
  ...(process.env.GITHUB_TOKEN && { authorization: `Bearer ${process.env.GITHUB_TOKEN}` }),
});

/** The latest release, or null if there is none (or the token cannot see it). Cached 5 minutes at the edge. */
export async function latestRelease(fetchImpl: typeof fetch = fetch): Promise<Release | null> {
  const res = await fetchImpl(`${API}/repos/${REPO}/releases/latest`, {
    headers: headers('application/vnd.github+json'),
    cf: { cacheTtl: 300, cacheEverything: true },
  } as RequestInit);
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`latest release: HTTP ${res.status}`);
  return res.json();
}

/** The asset's bytes as a download response from our own domain, or null if the release has no such asset. */
export async function assetResponse(name: string, fetchImpl: typeof fetch = fetch): Promise<Response | null> {
  if (!servable(name)) return null;
  const asset = (await latestRelease(fetchImpl))?.assets?.find((a) => a.name === name);
  if (!asset) return null;
  // The API answers with a redirect to the storage host; fetch follows it here, on the server.
  const res = await fetchImpl(`${API}/repos/${REPO}/releases/assets/${asset.id}`, { headers: headers('application/octet-stream') });
  if (!res.ok || !res.body) throw new Error(`release asset ${name}: HTTP ${res.status}`);
  if (name === 'appcast.xml') {
    return new Response(rewriteAppcast(await res.text()), {
      headers: { 'content-type': 'application/xml; charset=utf-8', 'cache-control': 'public, max-age=300' },
    });
  }
  return new Response(res.body, {
    headers: {
      'content-type': name.endsWith('.sha256') ? 'text/plain; charset=utf-8' : 'application/octet-stream',
      'content-disposition': `attachment; filename="${name}"`,
      ...(res.headers.get('content-length') && { 'content-length': res.headers.get('content-length')! }),
      'cache-control': 'public, max-age=300',
    },
  });
}

/**
 * The appcast as Sparkle reads it, with every download URL moved to https://<SHEPETAL_DOMAIN>/download/<name>.
 * Only the URLs change: the EdDSA signatures cover the files, not their addresses, so updates still verify.
 */
export function rewriteAppcast(xml: string, origin = siteOrigin()): string {
  return xml.replace(/https:\/\/github\.com\/[^"'\s<>]+\/releases\/download\/[^/"'\s<>]+\/([^"'\s<>]+)/g, (_, file) => `${origin}/download/${file}`);
}
