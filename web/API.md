# shepetal account API

The contract between this service and the shepetal apps. The apps are built against exactly this text: change both together. `web/e2e/run.mjs` drives it end to end.

- Base URL https://shepetal.app (SHEPETAL_DOMAIN in wrangler.toml); the apps override it with SHEPETAL_ACCOUNT_URL. The old host, https://shepetal.backant.io, which released builds call, is a 301 to the same path and query on https://shepetal.app for every path, /api/* included. https://www.shepetal.app is a 301 to the apex.

## App sign-in: OAuth for native apps with PKCE (RFC 8252, RFC 7636)

The app makes a code_verifier (43 to 128 characters from A-Z a-z 0-9 - . _ ~), its code_challenge = base64url(SHA-256(code_verifier)) without padding, and a random state. It opens the login URL in a browser and waits for the redirect.

- GET /app/login?redirect_uri=<uri>&state=<random>&code_challenge=<base64url(sha256(verifier))>&code_challenge_method=S256
  - redirect_uri is matched EXACTLY against these, as a string. Anything else gets 400 and no redirect:
    - `shepetal://auth`: Mac and iPhone, through ASWebAuthenticationSession (callback scheme `shepetal`).
    - `http://127.0.0.1:<port>/callback`: Linux and Windows, a loopback listener on any port from 1 to 65535 (no leading zero). The host is exactly 127.0.0.1: not localhost, no userinfo, no other path, no query, no fragment.
  - state: 1 to 512 characters, returned unchanged. code_challenge: 43 base64url characters. code_challenge_method: S256 only. Otherwise 400.
  - With no web session, the site runs the normal Google sign-in (backant's Google client), then comes back to this same URL.
  - A user's first sign-in, web or app, starts their 30-day trial.
  - Signed in, it answers 200 with a consent page and never issues a code: "Sign in to the Shepetal app on this computer as <email>?", naming the app from redirect_uri ("Mac or iPhone app" for shepetal://auth, "desktop app" for the loopback), with a "Continue" button and a "Not you? Use another account" link. This holds right after a fresh Google sign-in too: one click.
  - "Not you? Use another account" is the same URL plus `&switch=1`: Google sign-in with the account chooser, then back to the consent page.
  - The GET sets a CSRF cookie (`__Host-app-login-csrf` on https: HttpOnly, SameSite=Lax, 10 minutes, sealed with the email the page shows) and puts its value in the form.
- POST /app/login (the consent form, form-encoded): redirect_uri, state, code_challenge, code_challenge_method and csrf.
  - 403 unless csrf equals the CSRF cookie (compared in constant time) and the Origin header is the site's origin. 401 without a session. 403 when another account is signed in than the page showed. 400 for fields that fail the GET rules.
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
- POST /api/checkout (Bearer token or web session) with JSON {plan: "lifetime" | "monthly", code?: string}; no body or no plan is "lifetime". 200 {url} to a Stripe Checkout session:
  - lifetime: mode payment, the one-time $23.99 price (lookup_key shepetal_lifetime), client_reference_id = user id.
  - monthly: mode subscription, the $0.99 monthly price (lookup_key shepetal_monthly), subscription metadata {app: "shepetal", user_id}. No client_reference_id: backant.io's own handler treats a subscription checkout's client_reference_id as its client id.
  - Both: Stripe Tax (automatic_tax; prices tax-inclusive, in USD and in EUR for EU buyers; tax code txcd_10202000, Downloadable Software, personal use, on both products; tax_id_collection for businesses; customer_update address and name auto). The EU consent: consent_collection terms_of_service required, the checkbox text asking for delivery right away and acknowledging the end of the 14-day withdrawal right, with links to /terms and /refunds; the webhook stores when it was given (users.withdrawal_waived_at), the receipt (payment description) and every invoice (customer invoice footer) confirm it.
  - Both: the user's own Stripe customer (created once per user, so a first_time_transaction code works once per user), metadata {app: "shepetal", user_id, plan}. The customer's other open shepetal Checkout sessions are expired first, so a second tab cannot pay twice.
  - code: a shepetal promotion code (its coupon has metadata app=shepetal; PRODUCTHUNT takes $19.00 off the lifetime price), put on the session as a discount. Stripe's own code field (allow_promotion_codes) stays off: the Stripe account is shared with backant.io, whose codes (several 100% off, none limited to a product) would otherwise work on shepetal. 400 {error:"code_lifetime_only"} for a code with the monthly plan, 400 {error:"invalid_code"} for any other code, 400 {error:"code_not_applicable", message} when Stripe refuses it (ended, used, or a customer who has paid before).
  - Success returns to /account?purchased=1, cancel to /account. 401 when signed out; 400 {error:"invalid_plan"}; 409 {error:"already_active"} once the lifetime license is bought; 409 {error:"already_subscribed"} for monthly while a subscription has not ended (active, past due, or cancelled to its period end). A subscriber may buy the lifetime license: the subscription then ends at once with no further charge (switch to lifetime, below).
- POST /api/billing/portal (Bearer token or web session): 200 {url} to the Stripe Billing Portal for the user's customer (configuration with metadata app=shepetal: cancel at period end, update the card, invoices; returns to /account). 404 {error:"no_customer"} before any checkout; 401 when signed out.
- Plan settings (Bearer token or web session; 401 when signed out):
  - GET /api/account/plan: 200 {plan, status, email, trial, lifetime, subscription, actions}. plan and status as in GET /api/license.
    - trial: {ends_at, days_left} while the free trial runs, else null. days_left counts down, rounded up: 30 right after sign-in, 1 on the last day.
    - lifetime: {purchased_at} for the lifetime license, else null.
    - subscription (plan "subscription", else null): {status, paid_through, next_billing_date, ends_at, amount, currency, amount_display, interval: "month"}. status is "active" (renews: next_billing_date = paid_through), "cancels_at_period_end" (works until ends_at = paid_through; next_billing_date null), "past_due" (a renewal failed: update the card in the portal) or "ended" (ends_at = when it stopped). amount is what a renewal charges in the smallest unit (99), currency "usd", amount_display "$0.99".
    - actions: {cancel, resume, switch_to_lifetime, portal, choose_plan}, what the settings can offer now.
  - POST /api/billing/cancel: cancel at period end, never at once. No further charge; the license stays "active" until paid_through. Stored at once from Stripe's answer, so GET /api/license says renews: false right away. 200 {license, settings} (the GET /api/license body and the GET /api/account/plan body); 404 {error:"no_subscription"} when nothing renews.
  - POST /api/billing/resume: undo the cancel before the period ends. 200 {license, settings}; 404 {error:"no_subscription"} when nothing is cancelled to its period end.
  - nextCharge(user) in src/lib/stripe.ts (server-side, for pages): {amount, currency, at} of the next renewal, or null when nothing renews. GET /api/account/plan carries the same as subscription.next_billing_date and amount.
  - Switch to lifetime: POST /api/checkout {plan:"lifetime"} as a subscriber. When it is paid, the webhook makes the license lifetime and cancels the subscription at once (no proration, no final invoice, open renewal invoices voided), so nothing is charged again. Idempotent: the event is handled once, and a second run finds the subscription cancelled.
  - The Billing Portal (card, invoices, cancel): POST /api/billing/portal → {url}, with JSON {flow:"cancel"} to open on the cancel confirmation (returns to /account?cancelled=1); GET /api/billing/portal → 303 to the portal (GET ?flow=cancel likewise), so a plain link works. 404 {error:"no_customer"} before any checkout; 404 {error:"no_subscription"} for flow "cancel" without a renewing subscription (GET: 303 to /account?portal=none either way).
- POST /api/stripe/webhook (Stripe only; the Stripe-Signature is checked against STRIPE_WEBHOOK_SECRET over the raw body, 400 if it does not match). Each event id is handled once (table stripe_events): claimed before it runs and marked done after. A failure answers 500 and releases the id; a delivery while it runs answers 409; a claim that never finished (the Worker was cut off) is taken again after 2 minutes. Stripe retries each of these. Events:
  - checkout.session.completed and checkout.session.async_payment_succeeded with metadata.app "shepetal": mode payment with payment_status "paid" (or "no_payment_required") makes the user's lifetime license and keeps its PaymentIntent; a second lifetime payment for a user who has one is refunded. Mode subscription stores the subscription.
  - Never two charges: a subscription that arrives for an owner of the lifetime license, or beside another live subscription (the later one goes), is cancelled at once and what it was paid is refunded.
  - charge.refunded: a full refund of the lifetime payment ends the lifetime license (back to the trial dates, or a running subscription). Refunds of other payments change nothing.
  - customer.subscription.updated, customer.subscription.deleted (and .created), invoice.paid and invoice.payment_failed: the subscription is read fresh from Stripe, so the order of events does not matter, and stored if its metadata.app is "shepetal": plan, Stripe status, current_period_end, cancel_at_period_end and paid_through.
  - Every other event and object gets 200 and changes nothing. backant.io uses the same Stripe account, so its own checkouts and subscriptions arrive here too.

## Site

- GET /download (open, no sign-in: that happens in the app): 302 to `/download/<v>/Shepetal-<v>.dmg` (relative, `cache-control: public, max-age=300`), where `<v>` is LATEST, the `version` in `latest.json` in the R2 bucket `shepetal-releases`. Only `scripts/mac/promote.sh <v> --latest` writes it. Before the first promotion, a page saying it is coming soon (`no-cache`). A malformed `latest.json` is a 500.
- GET /download/<v>/<file>, where `<file>` is `Shepetal-<v>.dmg`, `Shepetal-<v>.dmg.sha256` or `appcast.xml`: the R2 object `releases/<v>/<file>`, `cache-control: public, max-age=31536000, immutable`, with an `etag` and `accept-ranges: bytes`. A single `Range` gets 206 with `content-range`, so a broken download resumes, and a range past the end gets 416. Any other version or file, and anything under `staging/` (CI uploads), is 404.
- GET /appcast.xml: the Sparkle feed the Mac app checks (its SUFeedURL). LATEST's `releases/<v>/appcast.xml` passed through as `application/xml; charset=utf-8`, `public, max-age=300`. Before the first promotion, an empty feed (`<channel/>`, `no-cache`), which Sparkle reads as no update.
- The trial starts at the user's first shepetal sign-in (web or app) and lasts 30 days, with no card. A lifetime license never expires.
- Web sign-in (Google, answered by the Worker): POST /api/auth/signin/google?callbackUrl=<path> from the sign-in form (403 without the site's Origin) answers 303 to Google with a state and a PKCE S256 challenge, kept in a sealed one-time cookie (`__Host-shepetal-oauth`, 10 minutes). Google returns to GET /api/auth/callback/google (the redirect URI registered at Google): the state must match, the code is exchanged with the verifier, and the id_token's iss, aud/azp, exp and email_verified are checked. Then the session cookie (`__Host-shepetal-session`: HttpOnly, Secure, SameSite=Lax, host-only, 30 days, AES-GCM sealed) and a 302 to `callbackUrl`, a path on the site only. Any failure is a 302 to /login?error=<code>. POST /api/auth/signout (site Origin) clears the session and answers 303 to /. GET /api/auth/providers describes the Google provider (signinUrl, callbackUrl). Any other /api/* path is a 404.
- A web session counts on POST /api/checkout, /api/billing/* and the other state-changing calls only with the site's Origin (else 401, as signed out). An Authorization header always wins: an invalid or malformed one is 401, never the cookie.
- GET /api/account (web session, site-internal: the account page reads it): 200 {license, settings} (the GET /api/license body and the GET /api/account/plan body), `cache-control: no-store`; 401 {error:"unauthorized"} when signed out.
- GET /account signed out is a 307 to /login?next=<the account URL>. GET /login signed in is a 307 to `next` (a path on the site, else /account).
- GET /account#plans: the plan choice ($23.99 once or $0.99 a month), where the apps' Buy button lands. Subscribers get Manage subscription there. Each user is keyed by their Google account email, lowercased.
