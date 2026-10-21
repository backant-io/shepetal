import { requestUser, siteUrl } from '@/lib/auth';
import { portalUrl } from '@/lib/stripe';

/**
 * The Stripe Billing Portal (card, invoices, cancel) for the signed-in user. POST answers {url}; JSON {flow: "cancel"}
 * opens it on the cancel confirmation. GET redirects there (303), so a plain link works; GET ?flow=cancel likewise.
 */
type Opened = { url: string } | { error: string; status: number };

async function open(req: Request, flow: unknown): Promise<Opened> {
  const user = await requestUser(req);
  if (!user) return { error: 'unauthorized', status: 401 };
  const url = await portalUrl(user, siteUrl(req), flow === 'cancel' ? 'cancel' : undefined);
  if (!url) return { error: flow === 'cancel' ? 'no_renewing_subscription' : 'no_customer', status: flow === 'cancel' ? 409 : 404 };
  return { url };
}

export async function POST(req: Request) {
  const body = (await req.json().catch(() => ({}))) as { flow?: unknown } | null;
  const r = await open(req, body?.flow);
  return 'url' in r ? Response.json({ url: r.url }) : Response.json({ error: r.error }, { status: r.status });
}

export async function GET(req: Request) {
  const r = await open(req, new URL(req.url).searchParams.get('flow'));
  if ('url' in r) return Response.redirect(r.url, 303);
  return Response.redirect(new URL(r.status === 401 ? '/account' : '/account?portal=none', siteUrl(req)), 303);
}
