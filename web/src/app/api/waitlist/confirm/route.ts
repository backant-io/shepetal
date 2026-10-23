import { getCloudflareContext } from '@opennextjs/cloudflare';
import { confirm, type WaitlistEnv } from '@/lib/waitlist';

// GET /api/waitlist/confirm?t= (API.md): the link in the confirmation email. 404 while WAITLIST is off.
export async function GET(req: Request) {
  return confirm(req, getCloudflareContext().env as unknown as WaitlistEnv);
}
