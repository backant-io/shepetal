import { planSettings, userById } from '@/lib/account';
import { requestUser } from '@/lib/auth';
import { setCancelAtPeriodEnd } from '@/lib/stripe';

/** Undo a cancel before the period ends: the subscription renews again. Answers the new plan settings. */
export async function POST(req: Request) {
  const user = await requestUser(req);
  if (!user) return Response.json({ error: 'unauthorized' }, { status: 401 });
  if (!(await setCancelAtPeriodEnd(user, false))) return Response.json({ error: 'no_cancelled_subscription' }, { status: 409 });
  return Response.json(planSettings((await userById(user.id)) ?? user));
}
