import { releases, releaseRoute } from '@/lib/download';

export const dynamic = 'force-dynamic';

// GET /download/<version>/<file> (API.md): a promoted release file from R2, with Range support (download.ts, releaseRoute). worker.ts serves it before Next; this route is the same code, for `next dev`.
export async function GET(req: Request) {
  return (await releaseRoute(releases(), req)) ?? new Response('Not found', { status: 404 });
}
