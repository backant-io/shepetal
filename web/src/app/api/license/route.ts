import { licenseOf } from '@/lib/account';
import { analyticsConfig, track, userId } from '@/lib/analytics';
import { bearer, neverUsed, userForToken } from '@/lib/tokens';

export async function GET(req: Request) {
  const token = bearer(req);
  // A token's first license check is an install (license_first_call); looked up only when analytics are on.
  const first = token && analyticsConfig().key ? await neverUsed(token) : false;
  const user = token && (await userForToken(token));
  if (!user) return Response.json({ error: 'invalid_token' }, { status: 401 });
  const license = licenseOf(user);
  if (first) await track('license_first_call', userId(user.email), { plan: license.plan, status: license.status });
  return Response.json(license, { headers: { 'cache-control': 'no-store' } });
}
