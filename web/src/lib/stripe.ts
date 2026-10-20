import Stripe from 'stripe';
import { activate, type User } from './account';

let stripe: Stripe | undefined;

/**
 * backant's Stripe account (same STRIPE_SECRET_KEY as backant.io). Uses the fetch
 * client because this runs on a Worker. Verify webhooks with
 * stripe.webhooks.constructEventAsync(body, sig, STRIPE_WEBHOOK_SECRET, undefined, Stripe.createSubtleCryptoProvider()).
 */
export function getStripe(): Stripe {
  const key = process.env.STRIPE_SECRET_KEY;
  if (!key) throw new Error('STRIPE_SECRET_KEY is not set');
  stripe ??= new Stripe(key, {
    apiVersion: '2025-02-24.acacia',
    httpClient: Stripe.createFetchHttpClient(),
  });
  return stripe;
}

// backant's Stripe account also sends backant.io's own checkouts to every webhook
// endpoint, so shepetal's sessions carry this tag and the webhook ignores the rest.
const APP = 'shepetal';

/** POST /api/checkout: a Checkout session for the one-time price. `base` is the site origin. */
export async function checkoutUrl(user: User, base: string): Promise<string> {
  const price = process.env.STRIPE_PRICE_ID;
  if (!price) throw new Error('STRIPE_PRICE_ID is not set');
  const session = await getStripe().checkout.sessions.create({
    mode: 'payment',
    line_items: [{ price, quantity: 1 }],
    client_reference_id: String(user.id),
    customer_email: user.email,
    metadata: { app: APP },
    success_url: `${base}/account?purchased=1`,
    cancel_url: `${base}/account`,
  });
  if (!session.url) throw new Error('Stripe returned a checkout session without a url');
  return session.url;
}

/** POST /api/stripe/webhook. 400 unless the Stripe-Signature matches STRIPE_WEBHOOK_SECRET. */
export async function handleWebhook(body: string, signature: string | null): Promise<Response> {
  const secret = process.env.STRIPE_WEBHOOK_SECRET;
  if (!secret) throw new Error('STRIPE_WEBHOOK_SECRET is not set');
  let event: Stripe.Event;
  try {
    event = await getStripe().webhooks.constructEventAsync(
      body,
      signature ?? '',
      secret,
      undefined,
      Stripe.createSubtleCryptoProvider(),
    );
  } catch {
    return Response.json({ error: 'invalid signature' }, { status: 400 });
  }
  // async_payment_succeeded: a delayed payment method (e.g. bank debit) completed with payment_status 'unpaid'.
  if (event.type === 'checkout.session.completed' || event.type === 'checkout.session.async_payment_succeeded') {
    const s = event.data.object;
    if (s.metadata?.app === APP && s.payment_status === 'paid') {
      if (!(await activate(Number(s.client_reference_id)))) {
        console.error(`stripe webhook: no user ${s.client_reference_id} for paid session ${s.id}`);
      }
    }
  }
  return Response.json({ received: true });
}
