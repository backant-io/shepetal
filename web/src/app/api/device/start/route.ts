import { siteUrl } from '@/lib/auth';
import { startDevice } from '@/lib/device';

export async function POST(req: Request) {
  return Response.json(await startDevice(siteUrl(req)));
}
