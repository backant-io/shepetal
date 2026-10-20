# shepetal account API

The contract between this service and the shepetal apps. The Mac app is built against exactly this text: change both together.

- Base URL https://shepetal.backant.io; the app overrides it with SHEPETAL_ACCOUNT_URL.
- POST /api/device/start: no auth; returns {device_code, user_code, verification_uri_complete, expires_in, interval}. verification_uri_complete is https://shepetal.backant.io/device?code=USER_CODE.
- POST /api/device/token with body {device_code}: 400 {error:"authorization_pending"|"slow_down"|"expired_token"|"access_denied"} until the user approves on /device, then 200 {access_token, email}. access_token is an opaque, revocable token stored hashed in D1.
- GET /api/license with Authorization: Bearer <access_token>: 200 {status:"trial"|"active"|"expired", trial_ends_at: ISO-8601 or null, email}; 401 for an invalid or revoked token.
- POST /api/checkout (Bearer token or web session): 200 {url} to a Stripe Checkout session for the one-time $4.99 price (STRIPE_PRICE_ID), with client_reference_id set to the user id.
- POST /api/stripe/webhook: on checkout.session.completed (signature verified), the user becomes "active" forever.
- GET /download (signed in): 302 to the latest backant-io/shepetal GitHub release asset matching Shepetal-*.pkg, or a page saying it is coming soon if none exists.
- The trial starts at the user's first shepetal sign-in (web or device) and lasts 30 days, with no card. "active" never expires. Each user is keyed by their backant Google account email.
