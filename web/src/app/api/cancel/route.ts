import { getCloudflareContext } from '@opennextjs/cloudflare';
import { declarationOf, ipKey, missingEmailHtml, otherOriginHtml, processDeclaration, receiptHtml, tooManyHtml } from '@/lib/cancel';
import { sesEnabled } from '@/lib/mail';

const html = (body: string, status = 200) =>
  new Response(body, { status, headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' } });

/**
 * The "Jetzt kündigen" button on /cancel (§ 312k BGB): no sign-in. Answered by worker.ts itself (no Next).
 * - Only from the site's own form: a browser sends its Origin with every POST, so another site cannot make its
 *   visitors' browsers send cancellations.
 * - At most 5 a minute per IP address (an IPv6 address by its /64, which one host can send from whole) and per email
 *   (the CANCEL_LIMIT binding, per Cloudflare location).
 * - The declaration counts as received when it is sent, so the receipt goes back at once, the same for every email,
 *   and everything else (the lookup, Stripe, the record, the emails) runs after it (processDeclaration), so the time
 *   it takes tells no one whether an email has an account.
 */
export async function POST(req: Request) {
  if (req.headers.get('origin') !== new URL(req.url).origin) return html(otherOriginHtml(), 403);
  const d = declarationOf(await req.formData().catch(() => new FormData()));
  if (!d) return html(missingEmailHtml(), 400);
  const { env, ctx } = getCloudflareContext();
  const keys = [`ip:${ipKey(req.headers.get('cf-connecting-ip') ?? '')}`, `email:${d.email.toLowerCase()}`];
  const limits = await Promise.all(keys.map((key) => env.CANCEL_LIMIT.limit({ key })));
  if (limits.some((l) => !l.success)) return html(tooManyHtml(), 429);
  ctx.waitUntil(processDeclaration(d));
  return html(receiptHtml(d, sesEnabled()));
}
