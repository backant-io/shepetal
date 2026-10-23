import { liveSubscription } from '@/lib/account';
import { requestUser, siteUrl } from '@/lib/auth';
import { checkoutUrl, CodeError, PLANS, type CheckoutPlan } from '@/lib/stripe';

/**
 * JSON {plan: "lifetime" | "monthly", code?: string}. No body, or no plan, is lifetime (the apps before plans send {}).
 * code is a shepetal promotion code (PRODUCTHUNT), lifetime only.
 */
async function bodyOf(req: Request): Promise<{ plan: CheckoutPlan; code?: string } | null> {
  const body = (await req.json().catch(() => ({}))) as { plan?: unknown; code?: unknown } | null;
  const plan = body?.plan ?? 'lifetime';
  if (!PLANS.includes(plan as CheckoutPlan)) return null;
  if (body?.code !== undefined && body.code !== null && typeof body.code !== 'string') return null;
  const code = typeof body?.code === 'string' && body.code.trim() ? body.code.trim() : undefined;
  return { plan: plan as CheckoutPlan, code };
}

export async function POST(req: Request) {
  const user = await requestUser(req);
  if (!user) return Response.json({ error: 'unauthorized' }, { status: 401 });
  const body = await bodyOf(req);
  if (!body) return Response.json({ error: 'invalid_plan' }, { status: 400 });
  // Already bought: never charge twice.
  if (user.status === 'active') return Response.json({ error: 'already_active' }, { status: 409 });
  // A subscriber may switch to lifetime (the subscription then ends at once, no further charge), never buy a second
  // subscription, past due or cancelled to its period end included.
  if (body.plan === 'monthly' && liveSubscription(user)) return Response.json({ error: 'already_subscribed' }, { status: 409 });
  try {
    return Response.json({ url: await checkoutUrl(user, siteUrl(req), body.plan, body.code) });
  } catch (e) {
    if (e instanceof CodeError) return Response.json({ error: e.code, message: e.message }, { status: 400 });
    throw e;
  }
}
