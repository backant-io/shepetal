import { licenseOf } from '@/lib/account';
import { requestUser, siteUrl } from '@/lib/auth';
import { checkoutUrl, PLANS, type CheckoutPlan } from '@/lib/stripe';

/** {plan: "lifetime" | "monthly"} picks the plan. No body, or no plan, is lifetime (the apps before plans send {}). */
async function planOf(req: Request): Promise<CheckoutPlan | null> {
  const body = (await req.json().catch(() => ({}))) as { plan?: unknown } | null;
  const plan = body?.plan ?? 'lifetime';
  return PLANS.includes(plan as CheckoutPlan) ? (plan as CheckoutPlan) : null;
}

export async function POST(req: Request) {
  const user = await requestUser(req);
  if (!user) return Response.json({ error: 'unauthorized' }, { status: 401 });
  const plan = await planOf(req);
  if (!plan) return Response.json({ error: 'invalid_plan' }, { status: 400 });
  // Already bought: never charge twice.
  if (user.status === 'active') return Response.json({ error: 'already_active' }, { status: 409 });
  // A subscriber may switch to lifetime (the subscription then ends at once, no further charge), never buy a second subscription.
  const license = licenseOf(user);
  if (plan === 'monthly' && license.plan === 'subscription' && license.status === 'active') {
    return Response.json({ error: 'already_subscribed' }, { status: 409 });
  }
  return Response.json({ url: await checkoutUrl(user, siteUrl(req), plan) });
}
