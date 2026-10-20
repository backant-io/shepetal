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
  - Then it responds 302 to `<redirect_uri>?code=<code>&state=<state>` (state percent-encoded, a space as %20). code is a one-time code: 60 s TTL, single use, stored as its SHA-256 in D1 with the code_challenge and the redirect_uri.
- POST /api/app/token with JSON {code, code_verifier, redirect_uri}:
  - 200 {access_token, email}. access_token is opaque (32 random bytes, base64url), revocable, stored as its SHA-256 in D1, and does not expire.
  - 400 {error:"invalid_grant"} for a wrong code_verifier, an unknown, reused or expired code, or a redirect_uri other than the one given to /app/login. The first redemption spends the code, even a failed one.
  - 400 {error:"invalid_request"} when a field is missing or is not a string.
  - Before calling it, the app checks that the state in the redirect equals the state it sent, and drops the redirect if not.

## License and purchase

- GET /api/license with Authorization: Bearer <access_token>: 200 {status:"trial"|"active"|"expired", trial_ends_at: ISO-8601 or null, email}; 401 for an invalid or revoked token. trial_ends_at is the first sign-in plus 30 days, and null for "active".
- POST /api/checkout (Bearer token or web session): 200 {url} to a Stripe Checkout session (mode payment) for the one-time $4.99 price (STRIPE_PRICE_ID), with client_reference_id set to the user id and metadata.app = "shepetal". Success returns to /account?purchased=1, cancel to /account. 401 when signed out; 409 {error:"already_active"} once bought.
- POST /api/stripe/webhook (Stripe only; the Stripe-Signature is checked against STRIPE_WEBHOOK_SECRET over the raw body, 400 if it does not match): a checkout.session.completed or checkout.session.async_payment_succeeded whose session has payment_status "paid" and metadata.app "shepetal" makes that user "active" forever. Every other event and session gets 200 and changes nothing. backant.io uses the same Stripe account, so its own checkouts (subscriptions, no shepetal metadata) arrive here too.

## Site

- GET /download (signed in): 302 to the latest backant-io/shepetal GitHub release asset matching Shepetal-*.pkg, or a page saying it is coming soon if none exists.
- The trial starts at the user's first shepetal sign-in (web or app) and lasts 30 days, with no card. "active" never expires. Each user is keyed by their Google account email, lowercased.
