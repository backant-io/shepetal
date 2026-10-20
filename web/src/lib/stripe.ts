import Stripe from 'stripe';

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
