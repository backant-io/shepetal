# shepetal web

The website and account service at https://shepetal.backant.io: the landing page, Google sign-in, the 30-day free trial with no card, the $4.99 one-time purchase, the installer download, and the app sign-in (OAuth with PKCE). The API the apps call is in [API.md](API.md).

## Architecture

- **Runtime:** Next.js 15 (App Router), built with `@opennextjs/cloudflare` and served by its own Cloudflare Worker, `shepetal-web`. It runs on workers.dev until launch. The shepetal.backant.io custom domain is added then.
- **Sign-in:** next-auth v5 with Google, JWT sessions and no adapter, the same setup as backant.io. Cookies are host-only, so a shepetal session never reaches backant.io.
- **Data:** shepetal's own D1 database, `shepetal` (binding `DB`). The tables are `users`, `tokens` and `app_codes`, and the schema and its rules are in `migrations/`. shepetal never touches backant's Postgres.
- **Payments:** Stripe Checkout in backant's Stripe account for the one-time price `STRIPE_PRICE_ID`. The webhook at `/api/stripe/webhook` sets the user to `active`.
- **Apps:** OAuth for native apps with PKCE (RFC 8252, RFC 7636): the app opens `/app/login`, which signs in with Google and redirects to `shepetal://auth` or `http://127.0.0.1:<port>/callback` with a one-time code, and `/api/app/token` trades the code for an opaque bearer token. Only the token's SHA-256 hash is stored, in `tokens`. `/api/license` checks the token.

| Path | What |
|---|---|
| `src/lib/db.ts` | `db()`: the D1 binding (inside a request only) |
| `src/lib/auth.ts` | next-auth (Google). The first sign-in creates the user and starts the trial |
| `src/lib/account.ts` | `upsertUser`, `getLicense`, `licenseOf` (the trial rule, tested in `account.test.ts`) |
| `src/lib/stripe.ts` | `getStripe()` |
| `src/lib/app-login.ts` | the app sign-in: redirect_uri allowlist, one-time codes, PKCE |
| `src/app/(site)/` | pages: the landing page and the account page |
| `src/app/api/` | the API routes in API.md |

## What comes from backant.io

Only the login and payment configuration, referred to here by variable name:

| Variable | Source |
|---|---|
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | backant's Google OAuth client. Live values are in AWS SSM as `/backant/WEB_GOOGLE_CLIENT_ID` and `/backant/WEB_GOOGLE_CLIENT_SECRET` (eu-central-1, profile `backant`). The same values are in `/Users/sorcecoder/github/backant/backant-mcp/web/.env.local` |
| `STRIPE_SECRET_KEY` | backant's Stripe account (live key). It is in SSM as `/backant/WEB_STRIPE_SECRET_KEY` |
| next-auth setup | copied from `backant-mcp/web/src/lib/auth.ts`: Google provider, JWT, `trustHost` |

These belong to shepetal alone:

| Variable | Value |
|---|---|
| `AUTH_SECRET` | a new random value, not backant's, so a session from one site is never valid on the other |
| `STRIPE_WEBHOOK_SECRET` | the signing secret of shepetal's own webhook endpoint |
| `STRIPE_PRICE_ID` | a var in `wrangler.toml` |
| `NEXTAUTH_URL`, `AUTH_URL` | `https://shepetal.backant.io` (vars in `wrangler.toml`). The OAuth callback is `https://shepetal.backant.io/api/auth/callback/google` |

Nothing about shepetal goes into backant-mcp or onto backant.io.

backant.io itself runs on AWS ECS (`backant-web-service`), not on a Worker. `backant-mcp/web/wrangler.toml` describes a `backant-web` Worker that is not deployed in the Hegler Technologies Cloudflare account. shepetal uses that Worker setup (`wrangler.toml`, `open-next.config.ts`) as its stack.

## Run locally

```sh
cd web
npm install                # also generates cloudflare-env.d.ts
npm run db:migrate:local   # local D1 in .wrangler/
npm run dev                # http://localhost:3000
npm test
npm run type-check
```

Put local values in `web/.env.development.local` for `npm run dev`, and in `web/.dev.vars` for `npm run preview` (the real Worker runtime, http://localhost:8787). Both use the same names: `AUTH_SECRET`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` and `STRIPE_PRICE_ID`. In `.dev.vars`, also set `AUTH_URL` and `NEXTAUTH_URL` to `http://localhost:8787`. Locally, use a Stripe test key and a test price.

**Never put values in `web/.env` or `web/.env.local`.** The OpenNext build copies those two files into the Worker bundle.

To fill the file without printing any value:

```sh
echo "AUTH_SECRET=$(openssl rand -hex 32)" >> .env.development.local
grep -E '^GOOGLE_CLIENT_(ID|SECRET)=' /Users/sorcecoder/github/backant/backant-mcp/web/.env.local >> .env.development.local
```

Local Google sign-in only works if `http://localhost:3000/api/auth/callback/google` is an authorized redirect URI on the OAuth client.

## Deploy

```sh
cd web
npm run db:migrate:remote
npm run deploy             # opennextjs-cloudflare build && deploy

export AWS_PROFILE=backant AWS_REGION=eu-central-1
ssm() { aws ssm get-parameter --with-decryption --name "$1" --query Parameter.Value --output text; }
openssl rand -hex 32 | npx wrangler secret put AUTH_SECRET
ssm /backant/WEB_GOOGLE_CLIENT_ID | npx wrangler secret put GOOGLE_CLIENT_ID
ssm /backant/WEB_GOOGLE_CLIENT_SECRET | npx wrangler secret put GOOGLE_CLIENT_SECRET
ssm /backant/WEB_STRIPE_SECRET_KEY | npx wrangler secret put STRIPE_SECRET_KEY
npx wrangler secret put STRIPE_WEBHOOK_SECRET   # paste the whsec_ value of shepetal's endpoint
```

Run `AUTH_SECRET` only once. A new value signs everyone out. Wrangler trims the trailing newline from piped values.

At launch, uncomment the `routes` line in `wrangler.toml` and deploy again: `sed -i '' 's/^# routes = /routes = /' wrangler.toml && npm run deploy`. The backant.io zone is in the same Cloudflare account.

## Notes for builders

- **Stripe on Workers:** `getStripe()` already uses the fetch HTTP client. To verify the webhook, read the raw body with `req.text()`, then call `stripe.webhooks.constructEventAsync(body, sig, process.env.STRIPE_WEBHOOK_SECRET, undefined, Stripe.createSubtleCryptoProvider())`.
- **Emails:** `upsertUser` lowercases emails. Store the email from the row it returns.
- **`/download`:** the GitHub API allows 60 unauthenticated calls an hour per IP, and Worker egress IPs are shared. Cache the latest-release lookup, for example with `fetch(url, { cf: { cacheTtl: 300 } })`.
- **Copy:** never name the speech model or any AI model in site copy, metadata or alt text. Write "on-device speech recognition".

## Preview

https://shepetal-web.business-c0d.workers.dev (workers.dev only, no custom domain yet). The D1 database `shepetal` (`bd45470f-27b2-4564-aa94-850856413b3e`) has `0001_init.sql` applied. The secrets `AUTH_SECRET`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` and `STRIPE_SECRET_KEY` are set. `STRIPE_WEBHOOK_SECRET` and `STRIPE_PRICE_ID` are not, because the Stripe objects do not exist yet, so `/api/checkout` and `/api/stripe/webhook` fail until action 2 is done. Google sign-in redirects to shepetal.backant.io (`AUTH_URL`), so it only completes after go-live.

## Pavel actions

1. In Google Cloud Console, go to APIs & Services, then Credentials, and open backant's OAuth client (the one `GOOGLE_CLIENT_ID` names). Add the authorized redirect URI `https://shepetal.backant.io/api/auth/callback/google` and the JavaScript origin `https://shepetal.backant.io`. Add `http://localhost:3000/api/auth/callback/google` too if it is missing. The Google consent screen will show backant's app name.
2. In the backant Stripe account (live), create a "Shepetal" product with a one-time $4.99 USD price and put its ID in `STRIPE_PRICE_ID` in `wrangler.toml`. Then create a webhook endpoint at `https://shepetal.backant.io/api/stripe/webhook` for `checkout.session.completed` and `checkout.session.async_payment_succeeded`, and set its signing secret as `STRIPE_WEBHOOK_SECRET`. The Stripe MCP can do both.
3. After action 2: put the price ID in `STRIPE_PRICE_ID` in `wrangler.toml`, run `npm run db:migrate:remote` (0002_app_login), `npx wrangler secret put STRIPE_WEBHOOK_SECRET` with the endpoint's signing secret, and `npm run deploy`. The other deploy steps above are done. The full ordered list, with smoke tests, is [GO-LIVE.md](GO-LIVE.md).
4. Go live: `cd web && sed -i '' 's/^# routes = /routes = /' wrangler.toml && npm run deploy`.
