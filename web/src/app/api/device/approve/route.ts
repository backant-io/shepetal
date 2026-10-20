import { upsertUser } from '@/lib/account';
import { auth } from '@/lib/auth';
import { approveDevice } from '@/lib/device';

/**
 * Called by the /device page for the signed-in user (web session).
 * Body {user_code, approve}: approve false denies. 200 {ok: true}, 401 signed out,
 * 403 cross-site, 404 {error: "invalid_code"} for an unknown, expired or already used code.
 */
export async function POST(req: Request) {
  if (req.headers.get('origin') !== new URL(req.url).origin) return Response.json({ error: 'forbidden' }, { status: 403 });
  const email = (await auth())?.user?.email;
  if (!email) return Response.json({ error: 'unauthorized' }, { status: 401 });
  const body = (await req.json().catch(() => null)) as { user_code?: unknown; approve?: unknown } | null;
  if (typeof body?.user_code !== 'string') return Response.json({ error: 'invalid_request' }, { status: 400 });
  const user = await upsertUser(email);
  return (await approveDevice(body.user_code, user.email, body.approve !== false))
    ? Response.json({ ok: true })
    : Response.json({ error: 'invalid_code' }, { status: 404 });
}
