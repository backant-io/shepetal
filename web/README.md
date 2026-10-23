# shepetal web

The website and account service at https://shepetal.app (`SHEPETAL_DOMAIN` in `wrangler.toml` [vars], the one place the domain is set): the landing page, Google sign-in, the 30-day free trial with no card, the two plans ($23.99 once or $0.99 a month), the installer download, and the app sign-in (OAuth with PKCE). The API the apps call is in [API.md](API.md).

## Architecture

- **Runtime:** Next.js 16 (App Router), built with `@opennextjs/cloudflare` and served by its own Cloudflare Worker, `shepetal-web`. `worker.ts` is the entry: it applies the host rules (`src/lib/site.ts`: www to the apex; the old host `shepetal.backant.io` is a 301 to the domain for every path, `/api/*` included), then hands over to OpenNext's worker. The custom domains are attached at launch (GO-LIVE.md, step 5).
- **Sign-in:** next-auth v5 with Google, JWT sessions and no adapter, the same setup as backant.io. Cookies are host-only, so a shepetal session never reaches backant.io.
- **Data:** shepetal's own D1 database, `shepetal` (binding `DB`). The tables are `users`, `tokens`, `app_codes`, `stripe_events`, `cancellations` (what the "Verträge hier kündigen" button received, API.md) and `visitor_salts` (the daily analytics salt), and the schema and its rules are in `migrations/`. shepetal never touches backant's Postgres.
- **Payments:** Stripe Checkout in backant's Stripe account: the lifetime price (lookup_key `shepetal_lifetime`, mode payment) or the monthly price (`shepetal_monthly`, mode subscription), both with promotion codes. `scripts/stripe-setup.mjs` creates the products, prices, the PRODUCTHUNT code and the Billing Portal configuration, in test or live mode. The webhook at `/api/stripe/webhook` stores the lifetime license or the subscription; `/api/billing/portal` opens the Stripe Billing Portal.
- **Apps:** OAuth for native apps with PKCE (RFC 8252, RFC 7636): the app opens `/app/login`, which signs in with Google, asks the user to confirm on a consent page, and redirects to `shepetal://auth` or `http://127.0.0.1:<port>/callback` with a one-time code, and `/api/app/token` trades the code for an opaque bearer token. Only the token's SHA-256 hash is stored, in `tokens`. It ends 90 days after its last use, and `/api/app/revoke` ends it on Sign out. `/api/license` checks the token.

| Path | What |
|---|---|
| `src/lib/db.ts` | `db()`: the D1 binding (inside a request only) |
| `src/lib/auth.ts` | next-auth (Google). The first sign-in creates the user and starts the trial |
| `src/lib/account.ts` | `upsertUser`, `getLicense`, `licenseOf` (the trial rule, tested in `account.test.ts`) |
| `src/lib/stripe.ts` | `getStripe()`, checkout per plan, the Billing Portal, the webhook |
| `scripts/stripe-setup.mjs` | finds or creates the Stripe objects and prints their IDs |
| `src/lib/analytics.ts`, `src/lib/server-analytics.ts`, `src/lib/visitor-salt.ts` | PostHog (backant's project, US cloud), every event tagged `app=shepetal`, all sent by the Worker after the answer: no analytics code, cookie or storage in the browser, so no consent banner. Off unless the `POSTHOG_KEY` secret is set. Events: `$pageview`, `download_served`, `app_login_opened`, `app_login_consented`, `appcast_check`, `license_first_call`, `checkout_completed` (GO-LIVE.md, step 4). Visitors are an HMAC under a random salt per UTC day, kept in D1 and deleted after 48 h |
| `src/lib/app-login.ts` | the app sign-in: redirect_uri allowlist, one-time codes, PKCE |
| `src/app/(story)/page.tsx`, `src/components/story/` | the landing page: the approved "full scroll story". `choreography.ts` is the design's one table of scroll timings and writing windows (ported from its build.mjs); `story.generated.css` is generated from it (native CSS scroll timelines plus the paused-animation fallback that `StoryMotion.tsx` drives with `--p`) |
| `src/app/(site)/`, `src/components/account/`, `src/styles/site.css` | sign-in, the app consent page, the account and its plan settings, and the legal pages, in the landing page's system |
| `src/lib/download.ts` | `/download`, the release files and `/appcast.xml`, from the R2 bucket `shepetal-releases` |
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
| prices, portal | found by lookup_key and metadata app=shepetal. `STRIPE_PRICE_LIFETIME`, `STRIPE_PRICE_MONTHLY`, `STRIPE_PORTAL_CONFIG` override them |
| `SHEPETAL_DOMAIN` | `shepetal.app` (vars in `wrangler.toml`). `AUTH_URL` and `NEXTAUTH_URL` are `https://<SHEPETAL_DOMAIN>` unless set (local runs set them). The OAuth callback is `https://shepetal.app/api/auth/callback/google` |

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

Put local values in `web/.env.development.local` for `npm run dev`, and in `web/.dev.vars` for `npm run preview` (the real Worker runtime, http://localhost:8787). Both use the same names: `AUTH_SECRET`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET`. In `.dev.vars`, also set `AUTH_URL` to `http://localhost:8787` (it overrides the address built from `SHEPETAL_DOMAIN`). Locally, use a Stripe test key: `STRIPE_SECRET_KEY=sk_test_… node scripts/stripe-setup.mjs` creates the test prices, and `stripe listen --forward-to localhost:8787/api/stripe/webhook` gives the webhook secret.

**Never put values in `web/.env` or `web/.env.local`.** The OpenNext build copies those two files into the Worker bundle.

To fill the file without printing any value:

```sh
echo "AUTH_SECRET=$(openssl rand -hex 32)" >> .env.development.local
grep -E '^GOOGLE_CLIENT_(ID|SECRET)=' /Users/sorcecoder/github/backant/backant-mcp/web/.env.local >> .env.development.local
```

Local Google sign-in only works if `http://localhost:3000/api/auth/callback/google` is an authorized redirect URI on the OAuth client.

## Tests

| Command | What |
|---|---|
| `npm test`, `npm run type-check` | unit tests (vitest) and the types |
| `npm run e2e` | the real Worker (`wrangler dev`, a fresh local D1) with a fake Stripe API: sign-in, the app login, checkout per plan, the webhooks, and /account for a trial user, a subscriber and a lifetime owner |
| `node e2e/stripe-testmode.mjs` | both plans and the plan settings API against the real Stripe test API (`STRIPE_SECRET_KEY=sk_test_…`) |
| `node e2e/account-testmode.mjs` | the plan settings on /account in a headless browser, in Stripe test mode: subscribe, Manage billing, cancel at period end, resume, switch to lifetime |
| `node e2e/hosts.mjs` | the Worker on its three hostnames: on `shepetal.backant.io` every path, `/api/*` included, is a 301 to `SHEPETAL_DOMAIN`; the Stripe webhook answers on the domain; `www` is a 301 to the apex; Google's callback is on the domain |
| `node e2e/install-browser.mjs` | in a headless browser against a running Worker (`BASE`): `/install?ref=x&utm_source=y` navigates by itself to `/download?ref=x&utm_source=y` (aborted, so nothing downloads), and links ask for no prefetch but still navigate |
| `node e2e/design-match.mjs` | the landing page against the design's reference frames (1440×900 and 390×844), an optional sweep against its standalone preview (`SWEEP=1`), and the check that the key never covers text. Viewport-sized captures only |

The browser tests use `playwright-core` from `PLAYWRIGHT_CORE` and a chromium headless shell from `PLAYWRIGHT_BROWSERS_PATH`: no window, no focus, no clipboard.

## Deploy

Preview first: `npx opennextjs-cloudflare build && npx opennextjs-cloudflare upload` uploads a version without sending it traffic and prints its preview URL. Production (below) only at launch.

The prerendered pages, robots.txt and the sitemap are served from their build-time copies (`open-next.config.ts`): the Workers Free plan gives a request 10 ms of CPU, and a React render takes more. `opennextjs-cloudflare deploy` and `upload` copy them into the assets (populateCache). **A plain `wrangler deploy` or `wrangler versions upload` ships without them**, and every page is rendered again (no `x-opennext-cache: HIT`). The copies are read-only, so a page can never revalidate: a `revalidate`, revalidatePath, revalidateTag or `'use cache'` needs another incremental cache.

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

The `routes` in `wrangler.toml` attach the custom domains `shepetal.app`, `www.shepetal.app` and `shepetal.backant.io` on deploy. Both zones are in the same Cloudflare account. Attaching shepetal.app is a launch step (GO-LIVE.md, step 5).

## Notes for builders

- **Stripe on Workers:** `getStripe()` already uses the fetch HTTP client. To verify the webhook, read the raw body with `req.text()`, then call `stripe.webhooks.constructEventAsync(body, sig, process.env.STRIPE_WEBHOOK_SECRET, undefined, Stripe.createSubtleCryptoProvider())`.
- **Emails:** `upsertUser` lowercases emails. Store the email from the row it returns.
- **Downloads:** `/download`, `/download/<v>/<file>` and `/appcast.xml` (API.md) read the R2 bucket `shepetal-releases` (binding `RELEASES`) and never another server. LATEST is `latest.json` there, written only by `scripts/mac/promote.sh <v> --latest` after it has checked the files. Never add `public/appcast.xml`: it would shadow the route. To try it locally, put files with `npx wrangler r2 object put shepetal-releases/releases/<v>/<file> --local --file <file>` and `latest.json` the same way.
- **Worker requests:** the Workers Free plan allows 100,000 Worker requests a day for the whole Cloudflare account, shared with its other Workers; over it, every Worker on the account fails until 00:00 UTC. Static files (`_next/static`, fonts, images) do not count; pages, RSC payloads, `/install`, `/download` and the DMG do. So every `<Link>` has `prefetch={false}` (site.test.tsx checks it; Next has no setting for the whole site): a prefetch is one or more RSC requests per link in view, and a click costs one request anyway. A visit from `/` through Try 30 days free to the download is 4 Worker requests: `/`, `/install`, `/download`, the DMG.
- **Copy:** never name the speech model or any AI model in site copy, metadata or alt text. Write "on-device speech recognition".

## Email

`src/lib/mail.ts` sends plain text from support@shepetal.app, two ways:

- **To Pavel** (pavel@hegler.tech, where support@shepetal.app forwards): the `NOTIFY` binding (`[[send_email]]` in `wrangler.toml`), Email Routing's sending to a verified destination. It works on Workers Free, costs nothing, and can reach no other address. Every declaration on /cancel is sent here with what was done and what is left to do. `wrangler dev` (and so the e2e) only prints these emails; a deployed or preview version sends them for real.
- **To customers**: Amazon SES (v2 API, SigV4 signed with WebCrypto in `mail.ts`), only when the three secrets below are set. Without them no customer is emailed, and /cancel's receipt says so. With them, two emails go to customers, each to the address of the account, never to one a stranger typed: the § 312k(4) BGB confirmation of a cancellation (never with the reason as typed), and the purchase confirmation after a lifetime purchase or a subscription start (§ 356(6) Nr. 2 d BGB: what was bought, the price paid, the consent to delivery right away and the acknowledged loss of the withdrawal right). Without them, Pavel gets each text to send by hand.

Setting up SES (backant's AWS account, eu-central-1, which has production access; run with `AWS_PROFILE=backant`):

```sh
export AWS_PROFILE=backant AWS_REGION=eu-central-1
# 1. The domain identity, with Easy DKIM: prints three tokens.
aws sesv2 create-email-identity --email-identity shepetal.app --query DkimAttributes.Tokens
# 2. In Cloudflare DNS for shepetal.app, for each token: CNAME <token>._domainkey -> <token>.dkim.amazonses.com
#    (DNS only, not proxied). Then wait until this prints true:
aws sesv2 get-email-identity --email-identity shepetal.app --query VerifiedForSendingStatus
# 3. A user that can only send from support@shepetal.app, and its key:
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
aws iam create-user --user-name shepetal-ses-send
aws iam put-user-policy --user-name shepetal-ses-send --policy-name send-from-shepetal --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"ses:SendEmail\",\"Resource\":\"arn:aws:ses:eu-central-1:${ACCOUNT}:identity/shepetal.app\",\"Condition\":{\"StringEquals\":{\"ses:FromAddress\":\"support@shepetal.app\"}}}]}"
aws iam create-access-key --user-name shepetal-ses-send --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text
# 4. The Worker secrets, after a deploy (wrangler secret put fails while a newer preview version exists):
npx wrangler secret put SES_ACCESS_KEY_ID       # paste the first value of step 3
npx wrangler secret put SES_SECRET_ACCESS_KEY   # paste the second
echo eu-central-1 | npx wrangler secret put SES_REGION
```

Then cancel your own test subscription on /cancel: the confirmation should arrive at the account's address, and the notice to Pavel should say `Confirmation to the customer: sent to …`. A test-mode purchase should bring the purchase confirmation to the buyer's account address. The Privacy Policy already names Amazon Web Services for these emails.

## Preview

https://shepetal-web.business-c0d.workers.dev (the live version also answers on shepetal.backant.io; shepetal.app is attached at GO). Preview versions get their own URL from `wrangler versions upload`. The D1 database `shepetal` (`bd45470f-27b2-4564-aa94-850856413b3e`) has `0001_init.sql` applied. The secrets `AUTH_SECRET`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` and `STRIPE_SECRET_KEY` are set. `STRIPE_WEBHOOK_SECRET` may not be. The plan prices exist only in test mode until action 2 runs `scripts/stripe-setup.mjs --live`, so `/api/checkout` fails in production until then. Google sign-in comes back to https://shepetal.app, so it completes only there, after go-live.

## Pavel actions

1. In Google Cloud Console, go to APIs & Services, then Credentials, and open backant's OAuth client (the one `GOOGLE_CLIENT_ID` names). Add the authorized redirect URI `https://shepetal.app/api/auth/callback/google`, and `shepetal.app` under the consent screen's authorized domains (GO-LIVE.md, step 2). Add `http://localhost:3000/api/auth/callback/google` too if it is missing. The Google consent screen will show backant's app name.
2. In the backant Stripe account (live), run `node scripts/stripe-setup.mjs --live` with the live key (GO-LIVE.md, step 3): the $23.99 and $0.99 prices, the PRODUCTHUNT code and the Billing Portal configuration. After the deploy in action 4, move the webhook endpoint (we_1USl5ADrjgXysMQjYGGaUepu) to `https://shepetal.app/api/stripe/webhook` with every event it needs (GO-LIVE.md, step 3.2). Its signing secret stays `STRIPE_WEBHOOK_SECRET`.
3. After action 2: run `npm run db:migrate:remote` (0002_app_login, 0003_plans, 0004_cancellations: without it /cancel records nothing and Pavel's notice says so; 0007_visitor_salt), `npx wrangler secret put STRIPE_WEBHOOK_SECRET` with the endpoint's signing secret, and `npm run deploy`. The other deploy steps above are done. The full ordered list, with smoke tests, is [GO-LIVE.md](GO-LIVE.md).
4. Go live: check that the shepetal.app zone has no records on the apex or www, then `cd web && npm run deploy`, which attaches the custom domains (GO-LIVE.md, step 5).
