import { attribution, track, visitorId } from '@/lib/analytics';
import { download, releases } from '@/lib/download';

export const dynamic = 'force-dynamic';

// GET /download (API.md): open to everyone, sign-in happens in the app. 302 to the latest DMG, or a coming-soon page.
// A served download is counted (download_served) with the version and where the visitor came from (?ref=, utm_*).
export async function GET(req: Request) {
  const res = await download(releases());
  const version = res.status === 302 ? res.headers.get('location')?.split('/')[2] : undefined;
  if (version) await track('download_served', visitorId(req), { version, ...attribution(new URL(req.url).searchParams) });
  return res;
}
