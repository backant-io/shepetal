import { releases, releaseRoute } from '@/lib/download';

export const dynamic = 'force-dynamic';

// GET /appcast.xml (API.md): the Sparkle feed the Mac app checks (its SUFeedURL), counted as active (download.ts, releaseRoute). worker.ts serves it before Next; this route is the same code, for `next dev`.
export async function GET(req: Request) {
  return (await releaseRoute(releases(), req)) ?? new Response('Not found', { status: 404 });
}
