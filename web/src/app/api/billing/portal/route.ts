import { requestUser, siteUrl } from '@/lib/auth';
import { portalUrl } from '@/lib/stripe';

/** The Stripe Billing Portal (cancel, change the card, invoices) for the signed-in user's subscription. */
export async function POST(req: Request) {
  const user = await requestUser(req);
  if (!user) return Response.json({ error: 'unauthorized' }, { status: 401 });
  const url = await portalUrl(user, siteUrl(req));
  if (!url) return Response.json({ error: 'no_customer' }, { status: 404 });
  return Response.json({ url });
}
