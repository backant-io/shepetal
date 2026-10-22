import { releases, releaseRoute } from '@/lib/download';

export const dynamic = 'force-dynamic';

// GET /download (API.md): open to everyone, sign-in happens in the app. 302 to the latest DMG, or coming soon (download.ts, releaseRoute). worker.ts serves it before Next; this route is the same code, for `next dev`.
export async function GET(req: Request) {
  return (await releaseRoute(releases(), req)) ?? new Response('Not found', { status: 404 });
}
