# Going live: shepetal.backant.io

Do these in order. Steps marked **Pavel** need an account only Pavel has. Run every command from `web/` on `main`, with wrangler logged in to Hegler Technologies (`npx wrangler whoami`) and `AWS_PROFILE=backant`. No command here prints a secret.

## 1. Merge (Pavel)

1. Into `feat/web`: the feat/web-e2e PR (app sign-in with PKCE, `web/e2e`, this file; #85 and #105 are already in), then #84 (help). The `web e2e` check must stay green.
2. Then #69 (`feat/web` into `main`).
3. #70 (Mac sign-in with PKCE) can merge any time: its sign-in gate is off unless the app bundle has `ShepetalRequiresSignIn` = true. Turn that key on in the release build only after step 6 passes.
4. backant-io/backant-mcp #84 only adds a test, and shepetal does not depend on it. Merging it to `main` starts the `Deploy to Production` workflow for backant.io, which has failed on its last 3 runs (since 2026-09-11). Merge it whenever backant's deploy is healthy. backant.io needs no change, config or redeploy for shepetal.

## 2. Google OAuth (Pavel)

Google Cloud Console → APIs & Services → Credentials → backant's OAuth client (the ID in SSM `/backant/WEB_GOOGLE_CLIENT_ID`):

- Authorized redirect URIs: **add** `https://shepetal.backant.io/api/auth/callback/google`. Keep `https://backant.io/api/auth/callback/google`.
- Nothing else. The apps' `shepetal://auth` and `http://127.0.0.1:<port>/callback` are shepetal's own redirect URIs, not Google's: never add them to Google. No JavaScript origin is needed (server-side code flow). `backant.io` is already an authorized domain, which covers the subdomain.
- The consent screen shows backant's app name.

## 3. Stripe (Pavel, backant account, live mode)

1. Create or update the products, prices, the PRODUCTHUNT code and the Billing Portal configuration (prints the IDs, changes nothing on a second run, archives the old $4.99 price):

   ```sh
   cd web && STRIPE_SECRET_KEY="$(aws ssm get-parameter --with-decryption --name /backant/WEB_STRIPE_SECRET_KEY --query Parameter.Value --output text)" node scripts/stripe-setup.mjs --live
   ```
2. The webhook endpoint `https://shepetal.backant.io/api/stripe/webhook` (we_1USl5ADrjgXysMQjYGGaUepu) must send `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `customer.subscription.updated`, `customer.subscription.deleted`, `invoice.paid` and `invoice.payment_failed`. Do not touch backant's own endpoint or its secret.
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

## 5. Custom domain (Pavel)

`AUTH_URL` is `https://shepetal.backant.io`, so Google sign-in and `/app/login` only work there, not on workers.dev.

1. Check that the backant.io zone has no DNS record for `shepetal` yet (Cloudflare dashboard → backant.io → DNS). A custom domain cannot replace one.
2. Uncomment the `routes` line in `web/wrangler.toml` (`routes = [{ pattern = "shepetal.backant.io", custom_domain = true }]`), merge that to `main`, and deploy:

```sh
sed -i '' 's/^# routes = /routes = /' wrangler.toml && npm run deploy
```

## 6. Smoke tests (anyone, right after step 5)

```sh
B=https://shepetal.backant.io
CH=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM   # any 43-character challenge
curl -sI $B/ | grep -iE '^(HTTP|strict-transport)'                       # 200, HSTS
curl -sI $B/ | grep -io "form-action[^;]*"                                # includes shepetal: http://127.0.0.1:* (the consent form's redirect)
curl -s $B/api/auth/providers                                           # callbackUrl https://shepetal.backant.io/api/auth/callback/google
curl -s -o /dev/null -w '%{http_code}\n' "$B/app/login?redirect_uri=https%3A%2F%2Fevil.com&state=x&code_challenge=$CH&code_challenge_method=S256"   # 400
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' "$B/app/login?redirect_uri=shepetal%3A%2F%2Fauth&state=x&code_challenge=$CH&code_challenge_method=S256"   # 307 https://accounts.google.com/...redirect_uri=https%3A%2F%2Fshepetal.backant.io%2Fapi%2Fauth%2Fcallback%2Fgoogle...
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
B, R = 'https://shepetal.backant.io', 'http://127.0.0.1:53682/callback'
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

If something is wrong: `npx wrangler rollback` (previous version) or remove the `routes` line and deploy, which takes shepetal.backant.io down without touching backant.io.

## Known limits

- A program on the user's computer can still open `/app/login` with its own loopback port and verifier (RFC 8252, section 8). It gets a code only if the user presses Continue on the consent page, which names the account and the kind of app. The token can only read the license and start a checkout.
- Access tokens end 90 days after their last use, and the apps revoke theirs on Sign out (`POST /api/app/revoke`). There is no page yet to revoke every token of an account. For that, use `UPDATE tokens SET revoked_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE email = '<email>'` with `npx wrangler d1 execute DB --remote --command`.
- The trial starts at the first sign-in, web included, so someone who signs in on the site before an installer exists loses trial days.
