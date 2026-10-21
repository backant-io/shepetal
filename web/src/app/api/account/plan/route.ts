import { planSettings } from '@/lib/account';
import { requestUser } from '@/lib/auth';

/** The plan settings (API.md): trial with days left, lifetime, or the subscription with its status, next billing date and amount. */
export async function GET(req: Request) {
  const user = await requestUser(req);
  if (!user) return Response.json({ error: 'unauthorized' }, { status: 401 });
  return Response.json(planSettings(user), { headers: { 'cache-control': 'no-store' } });
}
