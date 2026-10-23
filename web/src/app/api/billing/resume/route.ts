import { licenseOf, planSettings, userById } from '@/lib/account';
import { requestUser } from '@/lib/auth';
import { setCancelAtPeriodEnd } from '@/lib/stripe';

/** Undo a cancel before the period ends: the subscription renews again. 200 {license, settings}; 404 no_subscription. */
export async function POST(req: Request) {
  const user = await requestUser(req);
  if (!user) return Response.json({ error: 'unauthorized' }, { status: 401 });
  if (!(await setCancelAtPeriodEnd(user, false))) return Response.json({ error: 'no_subscription' }, { status: 404 });
  const now = (await userById(user.id)) ?? user;
  return Response.json({ license: licenseOf(now), settings: planSettings(now) });
}
