import { bearer, revokeToken } from '@/lib/tokens';

// POST /api/app/revoke (API.md): the app calls it on Sign out. 200 for any token, as in RFC 7009.
export async function POST(req: Request) {
  const token = bearer(req);
  if (!token) return Response.json({ error: 'invalid_token' }, { status: 401 });
  await revokeToken(token);
  return Response.json({ ok: true });
}
