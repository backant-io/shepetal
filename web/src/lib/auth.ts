import { upsertUser, type User } from './account';
import { s256 } from './app-login';
import { errorName } from './native';
import { safeNext } from './next-path';
import { same, seal, unb64url, unseal } from './session';
import { SITE_URL } from './site';
import { bearer, randomSecret, userForToken } from './tokens';
import { optedIn, recordTrialEmailsOptIn } from './trial-emails';

// Sign-in with Google (backant's OAuth client), answered by worker.ts without Next: an OpenID Connect code flow with
// PKCE S256 and a state bound to a sealed, one-time cookie, then the site's own session cookie (src/lib/session.ts).
// Cookies are host-only, so a shepetal session never reaches backant.io and the reverse.

/**
 * The origin links point at (Google's redirect_uri, Stripe's return URLs, the Origin checks, every redirect):
 * SITE_URL in production, whichever host the request came to; AUTH_URL in local runs. Never the Host header.
 */
export const siteUrl = (_req?: Request) => process.env.AUTH_URL || SITE_URL;

const SESSION = 'shepetal-session';
const SESSION_S = 30 * 86_400; // a session ends 30 days after sign-in
const OAUTH = 'shepetal-oauth'; // the Google sign-in in progress: state, PKCE verifier, where to return
const OAUTH_S = 600;
const GOOGLE_AUTH = 'https://accounts.google.com/o/oauth2/v2/auth';
const GOOGLE_TOKEN = 'https://oauth2.googleapis.com/token';
const ISSUERS = ['https://accounts.google.com', 'accounts.google.com'];

const https = () => siteUrl().startsWith('https:');
const secret = () => process.env.AUTH_SECRET ?? '';
/** The registered redirect URI: https://shepetal.app/api/auth/callback/google in production. */
export const googleCallbackUrl = () => `${siteUrl()}/api/auth/callback/google`;

/** __Host- needs https (Secure, Path=/, no Domain), so local http runs use the plain name. */
export const cookieName = (base: string) => (https() ? `__Host-${base}` : base);
/** Set-Cookie for `base`: host-only, HttpOnly, SameSite=Lax (sent on Google's and Stripe's top-level returns). */
export const setCookie = (base: string, value: string, maxAge: number) =>
  `${cookieName(base)}=${value}; Path=/; Max-Age=${maxAge}; HttpOnly; SameSite=Lax${https() ? '; Secure' : ''}`;
export function cookieValue(req: Request, base: string): string | null {
  const name = cookieName(base);
  for (const part of (req.headers.get('cookie') ?? '').split(';')) {
    const i = part.indexOf('=');
    if (i > 0 && part.slice(0, i).trim() === name) return part.slice(i + 1).trim();
  }
  return null;
}
export const sealFor = (base: string, data: Record<string, unknown>, maxAgeS: number) => seal(secret(), base, data, maxAgeS);
export async function unsealFrom(req: Request, base: string): Promise<Record<string, unknown> | null> {
  const v = cookieValue(req, base);
  return v ? unseal(secret(), base, v) : null;
}

/** The signed-in email of the web session, or null. */
export async function sessionEmail(req: Request): Promise<string | null> {
  const e = (await unsealFrom(req, SESSION))?.e;
  return typeof e === 'string' ? e : null;
}

/** A state-changing POST from the site's own pages: browsers send Origin with every POST. */
export const sameOrigin = (req: Request) => req.headers.get('origin') === new URL(siteUrl()).origin;

const text = (body: string, status: number) =>
  new Response(body, { status, headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' } });
/** A redirect to a path on this site, always as an absolute URL on siteUrl() (never a bare path a browser could misread). */
export function redirectTo(path: string, status: number, ...cookies: string[]): Response {
  const headers = new Headers({ location: new URL(path, siteUrl()).href, 'cache-control': 'private, no-store' });
  for (const c of cookies) headers.append('set-cookie', c);
  return new Response(null, { status, headers });
}

/**
 * The caller of an API route: the app's bearer token if an Authorization header is sent (an invalid or malformed one
 * is null, never a fallback to the cookie), else the web session. A cookie counts on a state-changing request only
 * from the site's own pages (Origin), as SameSite=Lax alone would let a same-site, cross-origin page through.
 */
export async function requestUser(req: Request): Promise<User | null> {
  if (req.headers.has('authorization')) {
    const token = bearer(req);
    return token ? userForToken(token) : null;
  }
  if (req.method !== 'GET' && req.method !== 'HEAD' && !sameOrigin(req)) return null;
  const email = await sessionEmail(req);
  return email ? upsertUser(email) : null;
}

/**
 * Starts Google sign-in: a fresh state and PKCE verifier, sealed into the one-time OAuth cookie with where to return
 * (`next`, a path on this site) and whether the trial emails box was ticked (`trialEmails`, recorded by
 * googleCallback once the user row exists), and a redirect to Google. prompt=select_account shows the account chooser.
 */
export async function startGoogle(next: string, status: number, prompt?: 'select_account', trialEmails = false): Promise<Response> {
  const state = randomSecret();
  const verifier = randomSecret();
  const q = new URLSearchParams({
    response_type: 'code',
    client_id: process.env.GOOGLE_CLIENT_ID ?? '',
    redirect_uri: googleCallbackUrl(),
    scope: 'openid email profile',
    state,
    code_challenge: await s256(verifier),
    code_challenge_method: 'S256',
    ...(prompt && { prompt }),
  });
  const cookie = setCookie(OAUTH, await sealFor(OAUTH, { s: state, v: verifier, n: safeNext(next), ...(trialEmails && { t: 1 }) }, OAUTH_S), OAUTH_S);
  return new Response(null, { status, headers: { location: `${GOOGLE_AUTH}?${q}`, 'cache-control': 'no-store', 'set-cookie': cookie } });
}

/**
 * POST /api/auth/signin/google from the sign-in page's form: ?callbackUrl is where to return, and the posted form
 * carries the trial emails box (lib/trial-emails.ts), unticked unless the visitor ticked it. 303 to Google.
 */
export async function signInPost(req: Request): Promise<Response> {
  if (!sameOrigin(req)) return text('Forbidden', 403);
  const form = await req.formData().catch(() => null);
  return startGoogle(new URL(req.url).searchParams.get('callbackUrl') ?? '/account', 303, undefined, optedIn(form));
}

/** POST /api/auth/signout from the account page: the session cookie goes, then the landing page. */
export async function signOutPost(req: Request): Promise<Response> {
  if (!sameOrigin(req)) return text('Forbidden', 403);
  return redirectTo('/', 303, setCookie(SESSION, '', 0));
}

/** GET /api/auth/providers, as Auth.js answered it (the GO-LIVE smoke test and the e2e readiness probe read it). */
export async function providers(): Promise<Response> {
  const google = { id: 'google', name: 'Google', type: 'oidc', signinUrl: `${siteUrl()}/api/auth/signin/google`, callbackUrl: googleCallbackUrl() };
  return Response.json({ google }, { headers: { 'cache-control': 'no-store' } });
}

/** Google's token endpoint. GOOGLE_TOKEN_URL (the e2e's fake Google) counts only in a local http run, on loopback. */
function tokenUrl(): string {
  const fake = process.env.GOOGLE_TOKEN_URL;
  if (!fake || !siteUrl().startsWith('http://')) return GOOGLE_TOKEN;
  const host = new URL(fake).hostname;
  return host === '127.0.0.1' || host === 'localhost' ? fake : GOOGLE_TOKEN;
}

/**
 * The claims of an id_token that came straight from Google's token endpoint over TLS, so its signature need not be
 * checked (OpenID Connect Core 3.1.3.7, item 6); the rest of 3.1.3.7 is: the issuer, our client as the audience (a
 * string equal to it, or a list holding it with azp equal to it; azp, when sent, is always ours), not expired, not
 * issued in the future. Null when any of it fails.
 */
export function idTokenClaims(jwt: unknown, clientId: string, now = Date.now()): Record<string, unknown> | null {
  if (typeof jwt !== 'string' || !clientId) return null;
  const parts = jwt.split('.');
  if (parts.length !== 3) return null;
  let c: Record<string, unknown>;
  try {
    c = JSON.parse(new TextDecoder().decode(unb64url(parts[1])));
  } catch {
    return null;
  }
  if (!c || typeof c !== 'object') return null;
  if (typeof c.iss !== 'string' || !ISSUERS.includes(c.iss)) return null;
  // aud: our client id itself, compared whole; a list must hold it, and then azp must be our client (3.1.3.7, 3-5).
  if (typeof c.aud === 'string') {
    if (c.aud !== clientId) return null;
  } else if (!Array.isArray(c.aud) || !c.aud.some((a) => a === clientId) || c.azp !== clientId) return null;
  if (c.azp !== undefined && c.azp !== clientId) return null;
  if (typeof c.exp !== 'number' || c.exp * 1000 <= now) return null;
  if (typeof c.iat !== 'number' || c.iat * 1000 > now + 300_000) return null;
  return c;
}

/**
 * GET /api/auth/callback/google, the redirect URI registered at Google. The OAuth cookie is spent on every outcome.
 * Its state must match (constant time); the code is exchanged with the client secret and the PKCE verifier; the
 * id_token's claims are checked, and the email must be verified. The first sign-in creates the user and starts the
 * trial (upsertUser; later sign-ins keep trial_started_at); a tick in the trial emails box is recorded. Then the session cookie and a 302 to where the sign-in
 * started. Every failure is a 302 to /login?error=<code>, logged with the code and a short fixed cause (the token
 * endpoint's HTTP status, or an exception's class name) only.
 */
export async function googleCallback(req: Request): Promise<Response> {
  const spent = setCookie(OAUTH, '', 0);
  // The log line names the cause in a few fixed words, never a token, code, cookie or email.
  const fail = (code: 'AccessDenied' | 'Configuration', cause: string) => {
    console.error(`google sign-in: ${code} (${cause})`);
    return redirectTo(`/login?error=${code}`, 302, spent);
  };
  try {
    const q = new URL(req.url).searchParams;
    if (q.get('error')) return fail('AccessDenied', 'cancelled at Google');
    const o = await unsealFrom(req, OAUTH);
    const state = q.get('state');
    const code = q.get('code');
    if (!o || typeof o.s !== 'string' || typeof o.v !== 'string') return fail('Configuration', 'no valid sign-in cookie');
    if (!state || !code) return fail('Configuration', 'no code or state');
    if (!same(state, o.s)) return fail('Configuration', 'state mismatch');
    const clientId = process.env.GOOGLE_CLIENT_ID ?? '';
    const res = await fetch(tokenUrl(), {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' },
      body: new URLSearchParams({
        grant_type: 'authorization_code',
        code,
        redirect_uri: googleCallbackUrl(),
        code_verifier: o.v,
        client_id: clientId,
        client_secret: process.env.GOOGLE_CLIENT_SECRET ?? '',
      }),
    });
    if (!res.ok) return fail('Configuration', `token endpoint ${res.status}`);
    const claims = idTokenClaims(((await res.json()) as { id_token?: unknown }).id_token, clientId);
    if (!claims) return fail('Configuration', 'id_token claims refused');
    const email = typeof claims.email === 'string' ? claims.email.trim() : '';
    if (!email || claims.email_verified !== true) return fail('AccessDenied', 'email missing or not verified');
    const user = await upsertUser(email); // the first shepetal sign-in starts the 30-day trial
    if (o.t === 1) await recordTrialEmailsOptIn(user.email); // the trial emails box, ticked on /login
    const session = setCookie(SESSION, await sealFor(SESSION, { e: user.email }, SESSION_S), SESSION_S);
    return redirectTo(safeNext(typeof o.n === 'string' ? o.n : null), 302, spent, session);
  } catch (e) {
    return fail('Configuration', `exception ${errorName(e)}`);
  }
}

/**
 * worker.ts, before the page cache: /login signed in (and no ?error) goes on to `next`; /account signed out goes to
 * the sign-in page, which returns to it. Null: serve the page.
 */
export async function pageRedirect(req: Request, url: URL): Promise<Response | null> {
  if (url.pathname === '/login') {
    if (url.searchParams.get('error') || !(await sessionEmail(req))) return null;
    return redirectTo(safeNext(url.searchParams.get('next')), 307);
  }
  if (url.pathname === '/account' && !(await sessionEmail(req))) {
    return redirectTo(`/login?next=${encodeURIComponent(safeNext(url.pathname + url.search))}`, 307);
  }
  return null;
}
