import { getCloudflareContext } from '@opennextjs/cloudflare';
import { unsubscribe, unsubscribePage, type WaitlistEnv } from '@/lib/waitlist';

// GET /api/waitlist/unsubscribe?t= shows the button; POST unsubscribes, from the button or a mail app's one-click
// (RFC 8058). API.md.
export async function GET(req: Request) {
  return unsubscribePage(req);
}

export async function POST(req: Request) {
  return unsubscribe(req, getCloudflareContext().env as unknown as WaitlistEnv);
}
