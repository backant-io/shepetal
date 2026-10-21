import { planSettings, userById } from '@/lib/account';
import { requestUser } from '@/lib/auth';
import { setCancelAtPeriodEnd } from '@/lib/stripe';

/** Cancel at period end: no further charge, and the license works until the paid period ends. Answers the new plan settings. */
export async function POST(req: Request) {
  const user = await requestUser(req);
  if (!user) return Response.json({ error: 'unauthorized' }, { status: 401 });
  if (!(await setCancelAtPeriodEnd(user, true))) return Response.json({ error: 'no_renewing_subscription' }, { status: 409 });
  return Response.json(planSettings((await userById(user.id)) ?? user));
}
