import { cancelContract, declarationOf, missingEmailHtml, receiptHtml, recordCancellation } from '@/lib/cancel';

const html = (body: string, status = 200) =>
  new Response(body, { status, headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' } });

/**
 * The "Jetzt kündigen" button on /cancel (§ 312k BGB): no sign-in. Answered by worker.ts itself (no Next). The
 * declaration counts as received whatever happens next, so a failure at Stripe or in D1 is logged and the
 * confirmation is shown anyway. The answer is the same whether the email has an account or not.
 */
export async function POST(req: Request) {
  const d = declarationOf(await req.formData().catch(() => new FormData()));
  if (!d) return html(missingEmailHtml(), 400);
  let done: { userId: number | null; outcome: string } = { userId: null, outcome: 'error' };
  try {
    done = await cancelContract(d);
  } catch (e) {
    console.error('cancel: acting on the declaration failed', e instanceof Error ? e.message : e);
  }
  try {
    await recordCancellation(d, done.userId, done.outcome);
  } catch (e) {
    console.error('cancel: recording the declaration failed', e instanceof Error ? e.message : e);
  }
  return html(receiptHtml(d));
}
