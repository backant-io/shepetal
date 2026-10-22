import { assetResponse } from '@/lib/download';

// GET /download/<name> (API.md): the installer (or its .sha256) of the latest release, streamed from this domain.
// Public, like any download link: Sparkle updates fetch it without a session. 404 for anything else.
export async function GET(_req: Request, { params }: { params: Promise<{ name: string }> }) {
  const res = await assetResponse(decodeURIComponent((await params).name));
  return res ?? new Response('Not found', { status: 404 });
}
