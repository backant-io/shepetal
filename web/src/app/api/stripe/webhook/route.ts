import { handleWebhook } from '@/lib/stripe';

// The raw body: the signature is over the exact bytes Stripe sent.
export async function POST(req: Request) {
  return handleWebhook(await req.text(), req.headers.get('stripe-signature'));
}
