-- Two plans (API.md): lifetime ($23.99 once) and subscription ($0.99 a month).
-- users.status 'active' stays the lifetime license (every purchase before this migration was one).
-- A subscription lives in the sub_* columns, as the webhook last read it from Stripe.

-- 'lifetime' once bought, 'subscription' once a monthly checkout completed, NULL on the trial.
ALTER TABLE users ADD COLUMN plan TEXT CHECK (plan IN ('lifetime', 'subscription'));
-- The Stripe customer every checkout of this user goes through (one per user, so the
-- PRODUCTHUNT code's first_time_transaction rule holds per user) and the Billing Portal opens for.
ALTER TABLE users ADD COLUMN stripe_customer_id TEXT;
ALTER TABLE users ADD COLUMN sub_id TEXT;
-- Stripe's subscription status: active, trialing, past_due, unpaid, canceled, incomplete, incomplete_expired, paused.
ALTER TABLE users ADD COLUMN sub_status TEXT;
ALTER TABLE users ADD COLUMN current_period_end TEXT;
-- 1 once the subscriber cancelled: it keeps working until current_period_end, then ends.
ALTER TABLE users ADD COLUMN cancel_at_period_end INTEGER NOT NULL DEFAULT 0;
-- The end of the last period that was paid for. The license is a subscription while now < paid_through.
ALTER TABLE users ADD COLUMN paid_through TEXT;
-- What each renewal charges, in the smallest unit of sub_currency (99 and 'usd' for $0.99), for the plan settings.
ALTER TABLE users ADD COLUMN sub_amount INTEGER;
ALTER TABLE users ADD COLUMN sub_currency TEXT;
-- The PaymentIntent that paid for the lifetime license. A second lifetime payment is refunded; a refund of this one ends the license.
ALTER TABLE users ADD COLUMN lifetime_payment_intent TEXT;

UPDATE users SET plan = 'lifetime' WHERE status = 'active';

CREATE UNIQUE INDEX users_stripe_customer ON users (stripe_customer_id) WHERE stripe_customer_id IS NOT NULL;
CREATE INDEX users_sub ON users (sub_id) WHERE sub_id IS NOT NULL;

-- Stripe event ids: each event changes the account at most once, even when Stripe retries it.
-- A row is claimed (done 0) before the event runs and marked done 1 after. A claim older than 2 minutes that never
-- finished (the Worker was cut off) is taken again by Stripe's next retry, so no event is lost.
CREATE TABLE stripe_events (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL,
  received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  done INTEGER NOT NULL DEFAULT 0
);
