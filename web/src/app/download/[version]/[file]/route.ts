import { file, releases } from '@/lib/download';

export const dynamic = 'force-dynamic';

// GET /download/<version>/<file> (API.md): a promoted release file from R2, with Range support.
export async function GET(req: Request, { params }: { params: Promise<{ version: string; file: string }> }) {
  const p = await params;
  return file(releases(), req, p.version, p.file);
}
