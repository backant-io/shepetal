import { userById } from '@/lib/account';
import { track, userId } from '@/lib/analytics';
import { handleWebhook } from '@/lib/stripe';

type Session = {
  mode?: string;
  payment_status?: string;
  amount_total?: number | null;
  currency?: string | null;
  metadata?: Record<string, string> | null;
  customer_details?: { email?: string | null } | null;
  customer_email?: string | null;
};

// The raw body: the signature is over the exact bytes Stripe sent.
export async function POST(req: Request) {
  const body = await req.text();
  const res = await handleWebhook(body, req.headers.get('stripe-signature'));
  await countPayment(body, res);
  return res;
}

/**
 * Analytics: a shepetal checkout that handleWebhook took (200, signature checked) and had not seen before is a
 * payment (checkout_completed). The handling itself is all in lib/stripe.ts; this only reads what it accepted.
 */
async function countPayment(body: string, res: Response): Promise<void> {
  if (res.status !== 200) return;
  const answer = (await res.clone().json().catch(() => ({}))) as { duplicate?: boolean };
  if (answer.duplicate) return;
  const event = JSON.parse(body) as { type?: string; data?: { object?: Session } };
  const s = event.data?.object;
  if (!s || !['checkout.session.completed', 'checkout.session.async_payment_succeeded'].includes(event.type ?? '')) return;
  if (s.metadata?.app !== 'shepetal' || s.payment_status !== 'paid') return;
  const email =
    s.customer_details?.email ?? s.customer_email ?? (s.metadata.user_id ? (await userById(Number(s.metadata.user_id)))?.email : null);
  if (!email) return;
  await track('checkout_completed', userId(email), {
    plan: s.mode === 'subscription' ? 'monthly' : 'lifetime',
    amount: s.amount_total ?? undefined,
    currency: s.currency ?? undefined,
  });
}
