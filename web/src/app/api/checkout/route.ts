import { requestUser, siteUrl } from '@/lib/auth';
import { checkoutUrl } from '@/lib/stripe';

export async function POST(req: Request) {
  const user = await requestUser(req);
  if (!user) return Response.json({ error: 'unauthorized' }, { status: 401 });
  // Already bought: never charge twice.
  if (user.status === 'active') return Response.json({ error: 'already_active' }, { status: 409 });
  return Response.json({ url: await checkoutUrl(user, siteUrl(req)) });
}
