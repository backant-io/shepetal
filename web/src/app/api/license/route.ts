import { licenseOf } from '@/lib/account';
import { bearer, userForToken } from '@/lib/tokens';

export async function GET(req: Request) {
  const token = bearer(req);
  const user = token && (await userForToken(token));
  if (!user) return Response.json({ error: 'invalid_token' }, { status: 401 });
  return Response.json(licenseOf(user), { headers: { 'cache-control': 'no-store' } });
}
