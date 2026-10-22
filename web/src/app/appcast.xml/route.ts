import { assetResponse } from '@/lib/download';

// GET /appcast.xml (API.md): the Sparkle appcast of the latest release, with its download URLs on this domain.
export async function GET() {
  return (await assetResponse('appcast.xml')) ?? new Response('Not found', { status: 404 });
}
