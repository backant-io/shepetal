const LATEST = 'https://api.github.com/repos/backant-io/shepetal/releases/latest';

type Release = { assets?: { name: string; browser_download_url: string }[] };

/** The installer asset of a release, or null. */
export const installerOf = (r: Release) =>
  r.assets?.find((a) => /^Shepetal-.+\.pkg$/.test(a.name))?.browser_download_url ?? null;

/** URL of the Shepetal-*.pkg in the latest GitHub release, or null if there is none yet. */
export async function latestInstallerUrl(): Promise<string | null> {
  // Unauthenticated GitHub API: 60 calls/hour per IP, and Worker egress IPs are shared. Cache 5 min.
  const res = await fetch(LATEST, {
    headers: { accept: 'application/vnd.github+json', 'user-agent': 'shepetal-web' },
    cf: { cacheTtl: 300, cacheEverything: true },
  });
  if (res.status === 404) return null; // no release yet
  if (!res.ok) throw new Error(`GitHub latest release: HTTP ${res.status}`);
  return installerOf(await res.json());
}
