# shepetal account API

The contract between this service and the shepetal apps. The apps are built against exactly this text: change both together. `web/e2e/run.mjs` drives it end to end.

- Base URL https://shepetal.backant.io; the apps override it with SHEPETAL_ACCOUNT_URL.

## App sign-in: OAuth for native apps with PKCE (RFC 8252, RFC 7636)

The app makes a code_verifier (43 to 128 characters from A-Z a-z 0-9 - . _ ~), its code_challenge = base64url(SHA-256(code_verifier)) without padding, and a random state. It opens the login URL in a browser and waits for the redirect.

- GET /app/login?redirect_uri=<uri>&state=<random>&code_challenge=<base64url(sha256(verifier))>&code_challenge_method=S256
  - redirect_uri is matched EXACTLY against these, as a string. Anything else gets 400 and no redirect:
    - `shepetal://auth`: Mac and iPhone, through ASWebAuthenticationSession (callback scheme `shepetal`).
    - `http://127.0.0.1:<port>/callback`: Linux and Windows, a loopback listener on any port from 1 to 65535 (no leading zero). The host is exactly 127.0.0.1: not localhost, no userinfo, no other path, no query, no fragment.
  - state: 1 to 512 characters, returned unchanged. code_challenge: 43 base64url characters. code_challenge_method: S256 only. Otherwise 400.
  - With no next-auth session, the site runs the normal Google sign-in (backant's Google client), then comes back to this same URL.
  - A user's first sign-in, web or app, starts their 30-day trial.
  - Signed in, it answers 200 with a consent page and never issues a code: "Sign in to the Shepetal app on this computer as <email>?", naming the app from redirect_uri ("Mac or iPhone app" for shepetal://auth, "desktop app" for the loopback), with a "Continue" button and a "Not you? Use another account" link. This holds right after a fresh Google sign-in too: one click.
  - "Not you? Use another account" is the same URL plus `&switch=1`: Google sign-in with the account chooser, then back to the consent page.
  - The GET sets a CSRF cookie (`__Host-app-login-csrf` on https: HttpOnly, SameSite=Lax, 10 minutes) and puts the same value in the form.
- POST /app/login (the consent form, form-encoded): redirect_uri, state, code_challenge, code_challenge_method and csrf.
  - 403 unless csrf equals the CSRF cookie and the Origin header is the site's origin. 401 without a session. 400 for fields that fail the GET rules.
  - Then it responds 302 to `<redirect_uri>?code=<code>&state=<state>` (state percent-encoded, a space as %20). code is a one-time code: 60 s TTL, single use, stored as its SHA-256 in D1 with the code_challenge and the redirect_uri.
- POST /api/app/token with JSON {code, code_verifier, redirect_uri}:
  - 200 {access_token, email}. access_token is opaque (32 random bytes, base64url), revocable and stored as its SHA-256 in D1. It ends 90 days after its last use: every call that sends it (license, checkout) starts the 90 days again.
  - 400 {error:"invalid_grant"} for a wrong code_verifier, an unknown, reused or expired code, or a redirect_uri other than the one given to /app/login. The first redemption spends the code, even a failed one.
  - 400 {error:"invalid_request"} when a field is missing or is not a string.
  - Before calling it, the app checks that the state in the redirect equals the state it sent, and drops the redirect if not.
- POST /api/app/revoke with Authorization: Bearer <access_token>: the app calls it on Sign out. 200 {ok:true} for any token (RFC 7009), and the token gets 401 from then on. 401 without a token.

## License and purchase

- GET /api/license with Authorization: Bearer <access_token>: 200 {status, plan, trial_ends_at, paid_through, renews, payment_failed, email}; 401 for an invalid, revoked or expired (90 days unused) token.
  - status: "trial" | "active" | "expired". "active" means shepetal works now: a lifetime license, or a subscription paid through a date still ahead. The apps before plans read only status, trial_ends_at and email.
  - plan: "lifetime" | "subscription" | "trial".
    - lifetime: status "active" forever; trial_ends_at, paid_through null.
    - subscription: status "active" while now < paid_through, the end of the last paid period. After it, status follows the trial dates ("trial" inside the first 30 days, else "expired") and plan stays "subscription".
    - trial: status "trial", then "expired"; trial_ends_at is the first sign-in plus 30 days.
  - paid_through: ISO-8601 or null (lifetime, trial). For a renewal that failed, it is the start of the unpaid period, so the subscription stops there until it is paid.
  - renews: true while a subscription will charge again at paid_through (also while Stripe retries a failed payment); false once cancelled, so it ends at paid_through.
  - payment_failed: true while the last renewal is unpaid (Stripe status past_due or unpaid). The card is updated in the Billing Portal.
- POST /api/checkout (Bearer token or web session) with JSON {plan: "lifetime" | "monthly"}; no body or no plan is "lifetime". 200 {url} to a Stripe Checkout session:
  - lifetime: mode payment, the one-time $23.99 price (lookup_key shepetal_lifetime), client_reference_id = user id.
  - monthly: mode subscription, the $0.99 monthly price (lookup_key shepetal_monthly), subscription metadata {app: "shepetal", user_id}. No client_reference_id: backant.io's own handler treats a subscription checkout's client_reference_id as its client id.
  - Both: allow_promotion_codes, the user's own Stripe customer (created once per user, so a first_time_transaction code works once per user), metadata {app: "shepetal", user_id, plan}. The PRODUCTHUNT code takes $19.00 off the lifetime price only; Stripe refuses it on the monthly plan.
  - Success returns to /account?purchased=1, cancel to /account. 401 when signed out; 400 {error:"invalid_plan"}; 409 {error:"already_active"} once the lifetime license is bought; 409 {error:"already_subscribed"} for monthly while a subscription is active. A subscriber may buy the lifetime license: the subscription then stops renewing and runs to its period end.
- POST /api/billing/portal (Bearer token or web session): 200 {url} to the Stripe Billing Portal for the user's customer (configuration with metadata app=shepetal: cancel at period end, update the card, invoices; returns to /account). 404 {error:"no_customer"} before any checkout; 401 when signed out.
- POST /api/stripe/webhook (Stripe only; the Stripe-Signature is checked against STRIPE_WEBHOOK_SECRET over the raw body, 400 if it does not match). Each event id is handled once (table stripe_events); a failure answers 500 and releases the id so Stripe's retry runs it. Events:
  - checkout.session.completed and checkout.session.async_payment_succeeded with metadata.app "shepetal": mode payment with payment_status "paid" (or "no_payment_required") makes the user's lifetime license; mode subscription stores the subscription.
  - customer.subscription.updated, customer.subscription.deleted (and .created), invoice.paid and invoice.payment_failed: the subscription is read fresh from Stripe, so the order of events does not matter, and stored if its metadata.app is "shepetal": plan, Stripe status, current_period_end, cancel_at_period_end and paid_through.
  - Every other event and object gets 200 and changes nothing. backant.io uses the same Stripe account, so its own checkouts and subscriptions arrive here too.

## Site

- GET /download (signed in): 302 to the latest backant-io/shepetal GitHub release asset matching Shepetal-*.pkg, or a page saying it is coming soon if none exists.
- The trial starts at the user's first shepetal sign-in (web or app) and lasts 30 days, with no card. A lifetime license never expires.
- GET /account#plans: the plan choice ($23.99 once or $0.99 a month), where the apps' Buy button lands. Subscribers get Manage subscription there. Each user is keyed by their Google account email, lowercased.
