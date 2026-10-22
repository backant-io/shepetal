# Going live: shepetal.app

The site's domain is `SHEPETAL_DOMAIN` in `wrangler.toml` [vars] (`shepetal.app`); every URL the site builds comes from it (`src/lib/site.ts`). The Worker also keeps answering on the old host, `shepetal.backant.io`, which every released app build calls: there `/api/*` answers directly, and pages, `/app/login` (with its query) and `/appcast.xml` are a 301 to the same path on shepetal.app. `www.shepetal.app` is a 301 to the apex. `web/e2e/hosts.mjs` tests all three hosts on the Worker runtime.

Do these in order. Steps marked **Pavel** need an account only Pavel has. Run every command from `web/` on `main`, with wrangler logged in to Hegler Technologies (`npx wrangler whoami`) and `AWS_PROFILE=backant`. No command here prints a secret.

## 1. Merge (Pavel)

1. Into `feat/web`: the feat/web-e2e PR (app sign-in with PKCE, `web/e2e`, this file; #85 and #105 are already in), then #84 (help). The `web e2e` check must stay green.
2. Then #69 (`feat/web` into `main`).
3. #70 (Mac sign-in with PKCE) can merge any time: its sign-in gate is off unless the app bundle has `ShepetalRequiresSignIn` = true. Turn that key on in the release build only after step 6 passes.
4. backant-io/backant-mcp #84 only adds a test, and shepetal does not depend on it. Merging it to `main` starts the `Deploy to Production` workflow for backant.io, which has failed on its last 3 runs (since 2026-09-11). Merge it whenever backant's deploy is healthy. backant.io needs no change, config or redeploy for shepetal.

## 2. Google OAuth (done)

Done by Pavel on 22.10.26: backant's OAuth client has the redirect URI `https://shepetal.app/api/auth/callback/google`, and the consent screen is verified for shepetal.app. Keep `https://backant.io/api/auth/callback/google` and `https://shepetal.backant.io/api/auth/callback/google` (the live site uses the latter until the deploy in step 5, and a rollback would again).

`AUTH_URL` and `NEXTAUTH_URL` are no longer in `wrangler.toml`: the site sets both to `https://<SHEPETAL_DOMAIN>` (`src/lib/site.ts`), so sign-in always comes back to shepetal.app, whichever host it started on. The deploy in step 5 removes the old `AUTH_URL = https://shepetal.backant.io` vars from the live Worker. Check: `curl -s https://shepetal.app/api/auth/providers` shows `callbackUrl` `https://shepetal.app/api/auth/callback/google`. The apps' `shepetal://auth` and `http://127.0.0.1:<port>/callback` are shepetal's own redirect URIs, never Google's.

## 3. Stripe (Pavel, backant account, live mode)

1. Create or update the products, prices, the PRODUCTHUNT code and the Billing Portal configuration (prints the IDs, changes nothing on a second run, archives the old $4.99 price):

   ```sh
   cd web && STRIPE_SECRET_KEY="$(aws ssm get-parameter --with-decryption --name /backant/WEB_STRIPE_SECRET_KEY --query Parameter.Value --output text)" node scripts/stripe-setup.mjs --live
   ```
   The script sets the Billing Portal's return URL and its privacy and terms links from SHEPETAL_DOMAIN (`https://shepetal.app/account`, `/privacy`, `/terms`).
2. Move shepetal's webhook endpoint (we_1USl5ADrjgXysMQjYGGaUepu, today `https://shepetal.backant.io/api/stripe/webhook`) to the domain. Its id and signing secret stay the same, so `STRIPE_WEBHOOK_SECRET` does not change. Do this **after** step 5, once https://shepetal.app answers. Until then the old URL keeps working, because `/api/*` answers on the old host:

   ```sh
   stripe webhook_endpoints update we_1USl5ADrjgXysMQjYGGaUepu --live \
     --url https://shepetal.app/api/stripe/webhook \
     -d "enabled_events[]=checkout.session.completed" -d "enabled_events[]=checkout.session.async_payment_succeeded" \
     -d "enabled_events[]=customer.subscription.updated" -d "enabled_events[]=customer.subscription.deleted" \
     -d "enabled_events[]=invoice.paid" -d "enabled_events[]=invoice.payment_failed" -d "enabled_events[]=charge.refunded"
   ```

   Do not touch backant's own endpoint or its secret.
3. Copy that endpoint's signing secret (`whsec_…`) for step 4 if it is not set yet.

Both sites share this Stripe account, so each webhook sees the other's events. shepetal acts only on sessions and subscriptions with `metadata.app = "shepetal"` and answers everything else 200. backant's handler acts on every `mode=subscription` checkout that has a `client_reference_id`, so shepetal's subscription checkouts carry none (the user id is in metadata), and backant finds no client for shepetal's Stripe customers on subscription events. Filtering `metadata.app = "shepetal"` out in backant's handler as well is the safe follow-up.

## 4. Database, Worker and secrets

The preview Worker `shepetal-web` (https://shepetal-web.business-c0d.workers.dev) already exists, with `0001_init.sql` applied to the remote D1 and the secrets `AUTH_SECRET`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` and `STRIPE_SECRET_KEY` set (web/README.md, Preview). What is left:

```sh
cd web
git switch main && git pull
npm ci
npx wrangler whoami                      # Hegler Technologies
npx wrangler secret list                 # names only: AUTH_SECRET, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, STRIPE_SECRET_KEY
npm run db:migrate:remote                # applies what is not applied yet: 0002_app_login, 0003_plans (plan and subscription columns, stripe_events)
npx wrangler secret put STRIPE_WEBHOOK_SECRET   # paste the whsec_ value from step 3
npm run deploy
```

Analytics (backant's PostHog project, US cloud; off until this is set). The key goes in as a secret, straight from SSM, never printed. `POSTHOG_HOST` is already `https://us.i.posthog.com` in `wrangler.toml`; check that SSM agrees:

```sh
export AWS_PROFILE=backant AWS_REGION=eu-central-1
aws ssm get-parameter --name /backant/production/NEXT_PUBLIC_POSTHOG_HOST --query Parameter.Value --output text   # https://us.i.posthog.com
aws ssm get-parameter --with-decryption --name /backant/production/NEXT_PUBLIC_POSTHOG_KEY --query Parameter.Value --output text | npx wrangler secret put POSTHOG_KEY
```

The project is shared with backant, so every shepetal event and person carries `app = shepetal`: filter on it in PostHog. Server events: `download_served` (version, ref, utm_*), `appcast_check` (= active, app_version), `license_first_call` (= install, plan) and `checkout_completed` (= paid, plan, amount). Page views come from the browser, cookieless (memory persistence), with `$geoip_disable`. To check after the deploy: `curl -s https://shepetal.app/ | grep -c shepetal-analytics` is 1, and the events show up in PostHog's activity view with `app = shepetal`. To turn analytics off: `npx wrangler secret delete POSTHOG_KEY`.

If any of the four secrets is missing from the list, set it without printing it:

```sh
export AWS_PROFILE=backant AWS_REGION=eu-central-1
ssm() { aws ssm get-parameter --with-decryption --name "$1" --query Parameter.Value --output text; }
openssl rand -hex 32 | npx wrangler secret put AUTH_SECRET     # new; never backant's AUTH_SECRET or NEXTAUTH_SECRET
ssm /backant/WEB_GOOGLE_CLIENT_ID | npx wrangler secret put GOOGLE_CLIENT_ID
ssm /backant/WEB_GOOGLE_CLIENT_SECRET | npx wrangler secret put GOOGLE_CLIENT_SECRET
ssm /backant/WEB_STRIPE_SECRET_KEY | npx wrangler secret put STRIPE_SECRET_KEY
```

- Never set `AUTH_SECRET` again once it exists. A new value signs everyone out of the site (app tokens keep working).
- Never set `STRIPE_API_BASE` in production. It is for `web/e2e` only, and the code ignores it unless the key starts with `sk_test_`.
- The Google client secret now lives in two places. If it is rotated, update `/backant/WEB_GOOGLE_CLIENT_SECRET` and shepetal's `GOOGLE_CLIENT_SECRET` together.

## 5. Custom domains (Pavel)

`wrangler.toml` routes attach three custom domains on deploy: `shepetal.app`, `www.shepetal.app` and `shepetal.backant.io` (already attached today). Cloudflare creates their DNS records and certificates.

1. Check that the shepetal.app zone (Cloudflare → shepetal.app → DNS) has no A, AAAA or CNAME record on `shepetal.app` or `www`: a custom domain cannot replace one. On 22.10.26 the zone had no records.
2. Record the live version, for a rollback: `npx wrangler deployments list | tail -8`.
3. Deploy (this attaches the domains):

```sh
npm run deploy          # opennextjs-cloudflare build && opennextjs-cloudflare deploy
npx wrangler deployments list | tail -8
```

4. Wait until `curl -sI https://shepetal.app/` answers (the certificate takes a few minutes), then move the Stripe webhook (step 3.2).

To take the new domain down again without touching the old host: Workers & Pages → shepetal-web → Settings → Domains & Routes → remove `shepetal.app` and `www.shepetal.app`. `npx wrangler rollback <version>` restores the code; custom domains are not part of a version.

## 6. Smoke tests (anyone, right after step 5)

```sh
B=https://shepetal.app
O=https://shepetal.backant.io
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' $O/                # 301 https://shepetal.app/
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' "$O/app/login?state=x"   # 301 https://shepetal.app/app/login?state=x
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' $O/appcast.xml     # 301 https://shepetal.app/appcast.xml
curl -s -o /dev/null -w '%{http_code}\n' $O/api/license                     # 401, never a redirect (released apps)
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://www.shepetal.app/terms   # 301 https://shepetal.app/terms
CH=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM   # any 43-character challenge
curl -sI $B/ | grep -iE '^(HTTP|strict-transport)'                       # 200, HSTS
curl -sI $B/ | grep -io "form-action[^;]*"                                # includes shepetal: http://127.0.0.1:* (the consent form's redirect)
curl -s $B/api/auth/providers                                           # callbackUrl https://shepetal.app/api/auth/callback/google
curl -s -o /dev/null -w '%{http_code}\n' "$B/app/login?redirect_uri=https%3A%2F%2Fevil.com&state=x&code_challenge=$CH&code_challenge_method=S256"   # 400
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' "$B/app/login?redirect_uri=shepetal%3A%2F%2Fauth&state=x&code_challenge=$CH&code_challenge_method=S256"   # 307 https://accounts.google.com/...redirect_uri=https%3A%2F%2Fshepetal.app%2Fapi%2Fauth%2Fcallback%2Fgoogle...
curl -s -X POST $B/api/app/token -H 'content-type: application/json' -d '{"code":"x","code_verifier":"x","redirect_uri":"shepetal://auth"}'   # 400 {"error":"invalid_grant"}
curl -s -o /dev/null -w '%{http_code}\n' $B/api/license                  # 401
curl -s -o /dev/null -w '%{http_code}\n' -X POST $B/api/stripe/webhook -d '{}'   # 400
curl -s https://backant.io/ | grep -ci shepetal                         # 0: nothing about shepetal on backant.io
curl -s https://backant.io/sitemap.xml | grep -ci shepetal              # 0
```

Then a real sign-in as the Linux and Windows apps do it (loopback redirect, PKCE). It opens the browser. Sign in with Google, check that the page asks "Sign in to the Shepetal app on this computer as <you>?" and names the desktop app, and press Continue. The script waits for the redirect, checks the state, prints the license and a checkout link, signs out (revokes), and never prints the token:

```sh
python3 - <<'PY'
import base64, hashlib, http.server, json, secrets, urllib.error, urllib.parse, urllib.request, webbrowser
B, R = 'https://shepetal.app', 'http://127.0.0.1:53682/callback'
v = secrets.token_urlsafe(48); st = secrets.token_urlsafe(16)
ch = base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).rstrip(b'=').decode()
got = {}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        got.update(urllib.parse.parse_qsl(urllib.parse.urlparse(self.path).query))
        self.send_response(200); self.end_headers(); self.wfile.write(b'Signed in. You can close this tab.')
    def log_message(self, *a): pass
srv = http.server.HTTPServer(('127.0.0.1', 53682), H)
webbrowser.open(B + '/app/login?' + urllib.parse.urlencode(dict(redirect_uri=R, state=st, code_challenge=ch, code_challenge_method='S256')))
srv.handle_request()
assert got.get('state') == st, 'state changed'
def call(path, body=None, tok=None):
    h = {'content-type': 'application/json', **({'authorization': 'Bearer ' + tok} if tok else {})}
    return json.load(urllib.request.urlopen(urllib.request.Request(B + path, json.dumps(body).encode() if body is not None else None, h)))
t = call('/api/app/token', dict(code=got['code'], code_verifier=v, redirect_uri=R))
print('signed in as', t['email'])
print('license', call('/api/license', tok=t['access_token']))        # trial, trial_ends_at = now + 30 days
print('checkout', call('/api/checkout', {}, t['access_token'])['url'])  # https://checkout.stripe.com/...
input('Pay in the browser (live, $23.99, or $4.99 with PRODUCTHUNT), then press Enter: ')
print('license', call('/api/license', tok=t['access_token']))        # active, trial_ends_at null
print('sign out', call('/api/app/revoke', {}, t['access_token']))    # {'ok': True}
try: call('/api/license', tok=t['access_token']); print('FAIL: the revoked token still works')
except urllib.error.HTTPError as e: print('after sign out', e.code)  # 401
PY
```

- In Stripe → Developers → Webhooks → the shepetal endpoint: the delivery for that checkout answered 200. Refund the payment if it was a test; the license stays active.
- Sign in on https://backant.io and open its dashboard: backant's own login still works.
- Mac (#70): install a build with `ShepetalRequiresSignIn` = true, choose Sign in with Google in the menu, and check that Home shows "Free trial: 30 days left" and that fn dictates.

If something is wrong: `npx wrangler rollback <the version from step 5.2>`. Removing a custom domain in the dashboard takes that host down without touching backant.io.

## Known limits

- A program on the user's computer can still open `/app/login` with its own loopback port and verifier (RFC 8252, section 8). It gets a code only if the user presses Continue on the consent page, which names the account and the kind of app. The token can only read the license and start a checkout.
- Access tokens end 90 days after their last use, and the apps revoke theirs on Sign out (`POST /api/app/revoke`). There is no page yet to revoke every token of an account. For that, use `UPDATE tokens SET revoked_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE email = '<email>'` with `npx wrangler d1 execute DB --remote --command`.
- The trial starts at the first sign-in, web included, so someone who signs in on the site before an installer exists loses trial days.
