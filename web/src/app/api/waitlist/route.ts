import { getCloudflareContext } from '@opennextjs/cloudflare';
import { signup, type WaitlistEnv } from '@/lib/waitlist';

// POST /api/waitlist (API.md): the /waitlist form. 303 to /waitlist/thanks whatever the address; 404 while WAITLIST is
// off.
export async function POST(req: Request) {
  const { env, ctx } = getCloudflareContext();
  return signup(req, env as unknown as WaitlistEnv, (p) => ctx.waitUntil(p));
}
