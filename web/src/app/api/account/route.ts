import { licenseOf, planSettings } from '@/lib/account';
import { requestUser } from '@/lib/auth';

/** The account page's data (site-internal, API.md): the license and the plan settings, as cancel and resume answer. */
export async function GET(req: Request) {
  const user = await requestUser(req);
  if (!user) return Response.json({ error: 'unauthorized' }, { status: 401, headers: { 'cache-control': 'no-store' } });
  const now = Date.now();
  return Response.json({ license: licenseOf(user, now), settings: planSettings(user, now) }, { headers: { 'cache-control': 'no-store' } });
}
