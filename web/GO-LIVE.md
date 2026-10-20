# Going live: shepetal.backant.io

Do these in order. Steps marked **Pavel** need an account only Pavel has. Run every command from `web/` on `main`, with wrangler logged in to Hegler Technologies (`npx wrangler whoami`) and `AWS_PROFILE=backant`. No command here prints a secret.

## 1. Merge (Pavel)

1. Into `feat/web`, in this order: #85 (account API), the feat/web-e2e PR (app sign-in with PKCE, `web/e2e`, this file), then the pages PR and #84 (help). The pages PR must not add `/device` or `ApproveDevice`: the device login is gone (see API.md). Each must keep `web e2e` green.
2. Then #69 (`feat/web` into `main`).
3. Do not merge #70 (Mac sign-in) yet: the app still uses the device flow there, and it must move to `/app/login` with PKCE first. Merge it only after step 7 passes, because the app blocks dictation until it is signed in.
4. backant-io/backant-mcp #84 only adds a test, and shepetal does not depend on it. Merging it to `main` starts the `Deploy to Production` workflow for backant.io, which has failed on its last 3 runs (since 2026-09-11). Merge it whenever backant's deploy is healthy. backant.io needs no change, config or redeploy for shepetal.

## 2. Google OAuth (Pavel)

Google Cloud Console → APIs & Services → Credentials → backant's OAuth client (the ID in SSM `/backant/WEB_GOOGLE_CLIENT_ID`):

- Authorized redirect URIs: **add** `https://shepetal.backant.io/api/auth/callback/google`. Keep `https://backant.io/api/auth/callback/google`.
- Nothing else. The apps' `shepetal://auth` and `http://127.0.0.1:<port>/callback` are shepetal's own redirect URIs, not Google's: never add them to Google. No JavaScript origin is needed (server-side code flow). `backant.io` is already an authorized domain, which covers the subdomain.
- The consent screen shows backant's app name.

## 3. Stripe (Pavel, backant account, live mode)

1. Create a product "Shepetal" with a one-time price of $4.99 USD. Put the price ID (`price_…`) in `STRIPE_PRICE_ID` in `web/wrangler.toml` and merge that one-line change to `main`.
2. Create a **new** webhook endpoint `https://shepetal.backant.io/api/stripe/webhook` with the events `checkout.session.completed` **and** `checkout.session.async_payment_succeeded` (without the second, a delayed payment method never activates). Do not touch backant's existing endpoint or its secret.
3. Copy that endpoint's signing secret (`whsec_…`) for step 4.

Both sites share this Stripe account, so each webhook sees the other's checkouts. shepetal acts only on a paid session with `metadata.app = "shepetal"` and answers everything else 200 (the e2e sends a paid backant subscription checkout and checks that it grants nothing). backant's handler acts only on `mode=subscription`. If shepetal ever sells a subscription, filter backant's handler first.

## 4. Database, Worker and secrets

```sh
cd web
git switch main && git pull
npm ci
npx wrangler whoami                      # Hegler Technologies
npm run db:migrate:remote                # 0001_init, 0002_app_login
npm run deploy                           # creates shepetal-web on workers.dev

export AWS_PROFILE=backant AWS_REGION=eu-central-1
ssm() { aws ssm get-parameter --with-decryption --name "$1" --query Parameter.Value --output text; }
openssl rand -hex 32 | npx wrangler secret put AUTH_SECRET     # new; never backant's AUTH_SECRET or NEXTAUTH_SECRET
ssm /backant/WEB_GOOGLE_CLIENT_ID | npx wrangler secret put GOOGLE_CLIENT_ID
ssm /backant/WEB_GOOGLE_CLIENT_SECRET | npx wrangler secret put GOOGLE_CLIENT_SECRET
ssm /backant/WEB_STRIPE_SECRET_KEY | npx wrangler secret put STRIPE_SECRET_KEY
npx wrangler secret put STRIPE_WEBHOOK_SECRET                  # paste the whsec_ value from step 3
npx wrangler secret list                                        # names only: the five above
```

- Set `AUTH_SECRET` once. A new value signs everyone out of the site (app tokens keep working).
- Never set `STRIPE_API_BASE` in production. It is for `web/e2e` only, and the code ignores it unless the key starts with `sk_test_`.
- The Google client secret now lives in two places. If it is rotated, update `/backant/WEB_GOOGLE_CLIENT_SECRET` and shepetal's `GOOGLE_CLIENT_SECRET` together.

## 5. Custom domain (Pavel)

`AUTH_URL` is `https://shepetal.backant.io`, so Google sign-in and `/app/login` only work there, not on workers.dev.

1. Check that the backant.io zone has no DNS record for `shepetal` yet (Cloudflare dashboard → backant.io → DNS). A custom domain cannot replace one.
2. Add to `web/wrangler.toml`, merge to `main`, and deploy:

```toml
routes = [{ pattern = "shepetal.backant.io", custom_domain = true }]
```

```sh
npm run deploy
```

## 6. Smoke tests (anyone, right after step 5)

```sh
B=https://shepetal.backant.io
CH=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM   # any 43-character challenge
curl -sI $B/ | grep -iE '^(HTTP|strict-transport)'                       # 200, HSTS
curl -s $B/api/auth/providers                                           # callbackUrl https://shepetal.backant.io/api/auth/callback/google
curl -s -o /dev/null -w '%{http_code}\n' "$B/app/login?redirect_uri=https%3A%2F%2Fevil.com&state=x&code_challenge=$CH&code_challenge_method=S256"   # 400
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' "$B/app/login?redirect_uri=shepetal%3A%2F%2Fauth&state=x&code_challenge=$CH&code_challenge_method=S256"   # 307 https://accounts.google.com/...redirect_uri=https%3A%2F%2Fshepetal.backant.io%2Fapi%2Fauth%2Fcallback%2Fgoogle...
curl -s -X POST $B/api/app/token -H 'content-type: application/json' -d '{"code":"x","code_verifier":"x","redirect_uri":"shepetal://auth"}'   # 400 {"error":"invalid_grant"}
curl -s -o /dev/null -w '%{http_code}\n' $B/api/license                  # 401
curl -s -o /dev/null -w '%{http_code}\n' -X POST $B/api/stripe/webhook -d '{}'   # 400
curl -s https://backant.io/ | grep -ci shepetal                         # 0: nothing about shepetal on backant.io
curl -s https://backant.io/sitemap.xml | grep -ci shepetal              # 0
```

Then a real sign-in as the Linux and Windows apps do it (loopback redirect, PKCE). It opens the browser, waits for the redirect, checks the state, prints the license and a checkout link, and never prints the token:

```sh
python3 - <<'PY'
import base64, hashlib, http.server, json, os, secrets, urllib.parse, urllib.request, webbrowser
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
input('Pay in the browser (live, $4.99), then press Enter: ')
print('license', call('/api/license', tok=t['access_token']))        # active, trial_ends_at null
PY
```

- In Stripe → Developers → Webhooks → the shepetal endpoint: the delivery for that checkout answered 200. Refund the payment if it was a test; the license stays active.
- Sign in on https://backant.io and open its dashboard: backant's own login still works.
- Once #70 uses `/app/login`: install the Mac app, sign in from the menu, and check that Home shows "Free trial: 30 days left".

If something is wrong: `npx wrangler rollback` (previous version) or remove the `routes` line and deploy, which takes shepetal.backant.io down without touching backant.io.

## Known limits

- `/app/login` redirects without a consent page. Any program on a signed-in user's computer that opens it with its own loopback port and verifier gets a token for that user's license (RFC 8252, section 8). The token can only read the license and start a checkout.
- Access tokens do not expire, and there is no revoke endpoint yet (`revokeToken()` exists in `src/lib/tokens.ts`).
- The trial starts at the first sign-in, web included, so someone who signs in on the site before an installer exists loses trial days.
