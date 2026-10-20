import { pollDevice } from '@/lib/device';

export async function POST(req: Request) {
  const body = (await req.json().catch(() => null)) as { device_code?: unknown } | null;
  if (typeof body?.device_code !== 'string') return Response.json({ error: 'invalid_request' }, { status: 400 });
  const r = await pollDevice(body.device_code);
  return Response.json(r, { status: 'error' in r ? 400 : 200, headers: { 'cache-control': 'no-store' } });
}
