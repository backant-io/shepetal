import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { upsertUser } from './account';
import { s256 } from './app-login';
import { googleCallback, idTokenClaims, pageRedirect, providers, requestUser, sessionEmail, signInPost, signOutPost, siteUrl } from './auth';
import { db } from './db';
import { b64url, seal, unseal } from './session';
import { SITE_URL } from './site';
import { useTestDb } from './test-db';
import { createToken } from './tokens';

vi.mock('./db', () => import('./test-db'));
useTestDb();

// Google sign-in, answered without Next. Users are keyed by email, so whatever lets a wrong email through (a forged
// state, someone else's id_token, an unverified address) is an account and license takeover; whatever sends the
// browser off the site after sign-in is an open redirect.

const SECRET = 'auth-test-secret';
const CLIENT = 'client-123.apps.googleusercontent.com';
const GOOGLE_TOKEN = 'https://oauth2.googleapis.com/token';
Object.assign(process.env, { AUTH_SECRET: SECRET, GOOGLE_CLIENT_ID: CLIENT, GOOGLE_CLIENT_SECRET: 'google-client-secret' });

const ORIGIN = new URL(SITE_URL).origin;
const nowS = () => Math.floor(Date.now() / 1000);
const jwt = (claims: object) => `eyJhbGciOiJSUzI1NiJ9.${b64url(new TextEncoder().encode(JSON.stringify(claims)))}.c2ln`;
const claims = (over: object = {}) => ({ iss: 'https://accounts.google.com', aud: CLIENT, azp: CLIENT, sub: '1', email: 'A@Example.com', email_verified: true, iat: nowS(), exp: nowS() + 3600, ...over });
/** The Set-Cookie headers as one Cookie header (only cookies that are set, not cleared). */
const jar = (res: Response) =>
  res.headers.getSetCookie().filter((c) => !/Max-Age=0\b/.test(c)).map((c) => c.split(';')[0]).join('; ');
const cookieOf = (res: Response, name: string) => res.headers.getSetCookie().find((c) => c.startsWith(`${name}=`));

let token: ReturnType<typeof vi.fn>;
/** Google's token endpoint answering with this id_token (or this status). */
function google(idToken: string | null = jwt(claims()), status = 200) {
  token = vi.fn(async () => (status === 200 ? Response.json({ access_token: 'ya29.x', id_token: idToken }) : Response.json({ error: 'invalid_grant' }, { status })));
  vi.stubGlobal('fetch', token);
}
beforeEach(() => google());
afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  delete process.env.AUTH_URL;
  delete process.env.GOOGLE_TOKEN_URL;
});

/** The sign-in page's form: POST /api/auth/signin/google?callbackUrl=<next>, from the site itself. */
const start = (next = '/account', origin: string | null = siteUrl()) =>
  signInPost(new Request(`${siteUrl()}/api/auth/signin/google?callbackUrl=${encodeURIComponent(next)}`, { method: 'POST', headers: origin ? { origin } : {} }));
/** Google sends the browser back with ?code and ?state (or ?error). */
const back = (query: string, cookie = '') => googleCallback(new Request(`${siteUrl()}/api/auth/callback/google?${query}`, { headers: { cookie } }));
async function signIn(next = '/account') {
  const go = await start(next);
  const state = new URL(go.headers.get('location')!).searchParams.get('state')!;
  return back(`code=4%2Fabc&state=${encodeURIComponent(state)}&scope=email`, jar(go));
}
const users = async () => (await db().prepare('SELECT email, trial_started_at FROM users').all<{ email: string; trial_started_at: string }>()).results;
const failedWith = (res: Response, code: string) => {
  expect(res.status).toBe(302);
  expect(res.headers.get('location')).toBe(`${SITE_URL}/login?error=${code}`);
  expect(cookieOf(res, '__Host-shepetal-oauth')).toMatch(/Max-Age=0/); // the one-time cookie is spent
  expect(cookieOf(res, '__Host-shepetal-session')).toBeUndefined();
};

describe('starting Google sign-in', () => {
  it('sends the browser to Google with a state and a PKCE S256 challenge bound to a sealed one-time cookie', async () => {
    const res = await start('/app/login?state=x');
    expect(res.status).toBe(303);
    const to = new URL(res.headers.get('location')!);
    expect(to.origin + to.pathname).toBe('https://accounts.google.com/o/oauth2/v2/auth');
    const q = Object.fromEntries(to.searchParams);
    expect(q).toMatchObject({ response_type: 'code', client_id: CLIENT, redirect_uri: `${SITE_URL}/api/auth/callback/google`, scope: 'openid email profile', code_challenge_method: 'S256' });
    expect(q.prompt).toBeUndefined();
    expect(q.state).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const cookie = cookieOf(res, '__Host-shepetal-oauth')!;
    expect(cookie).toMatch(/; Path=\/; Max-Age=600; HttpOnly; SameSite=Lax; Secure$/);
    expect(cookie).not.toMatch(/Domain/i);
    const sealed = await unseal(SECRET, 'shepetal-oauth', cookie.split(';')[0].split('=')[1]);
    expect(sealed).toMatchObject({ s: q.state, n: '/app/login?state=x' });
    expect(q.code_challenge).toBe(await s256(sealed!.v as string));
    expect(cookie).not.toContain(sealed!.v as string); // the verifier never leaves the cookie in clear
  });

  it('keeps the state, the PKCE verifier and the return path unreadable in the cookie, and the email in the session', async () => {
    const go = await start('/account#plans');
    const value = jar(go).split('=')[1];
    const { s: state, v: verifier, n } = (await unseal(SECRET, 'shepetal-oauth', value))!;
    expect(n).toBe('/account#plans');
    const session = jar(await back(`code=x&state=${state}`, jar(go))).split('=')[1];
    for (const [cookie, plain] of [[value, state], [value, verifier], [value, '/account'], [value, 'plans'], [session, 'a@example.com'], [session, 'Example']] as const) {
      expect(cookie).not.toContain(plain);
      expect(Buffer.from(cookie as string, 'base64url').toString('latin1').toLowerCase()).not.toContain(String(plain).toLowerCase());
    }
  });

  it('refuses a POST from another site or without Origin (login CSRF)', async () => {
    for (const origin of ['https://evil.example', 'null', `${ORIGIN}.evil.example`, null]) {
      const res = await start('/account', origin);
      expect(res.status, String(origin)).toBe(403);
      expect(res.headers.get('set-cookie')).toBeNull();
    }
  });
});

describe('the Google callback', () => {
  it('signs in: exchanges the code with the verifier, creates the user once, sets the session and returns', async () => {
    const res = await signIn('/account?purchased=1#plans');
    expect(res.status).toBe(302);
    expect(res.headers.get('location')).toBe(`${SITE_URL}/account?purchased=1#plans`);
    const [url, init] = token.mock.calls[0] as [string, RequestInit];
    expect(url).toBe(GOOGLE_TOKEN);
    const sent = Object.fromEntries(new URLSearchParams(init.body as URLSearchParams));
    expect(sent).toMatchObject({ grant_type: 'authorization_code', code: '4/abc', redirect_uri: `${SITE_URL}/api/auth/callback/google`, client_id: CLIENT, client_secret: 'google-client-secret' });
    expect(sent.code_verifier).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const session = cookieOf(res, '__Host-shepetal-session')!;
    expect(session).toMatch(/; Path=\/; Max-Age=2592000; HttpOnly; SameSite=Lax; Secure$/);
    expect(cookieOf(res, '__Host-shepetal-oauth')).toMatch(/Max-Age=0/);
    expect(await sessionEmail(new Request(SITE_URL, { headers: { cookie: jar(res) } }))).toBe('a@example.com');
    const [row] = await users();
    expect(row.email).toBe('a@example.com'); // lowercased
    expect(Date.now() - Date.parse(row.trial_started_at)).toBeLessThan(5000); // the first sign-in starts the trial
    // A later sign-in never moves the trial start.
    await db().prepare("UPDATE users SET trial_started_at = '2026-01-01T00:00:00.000Z'").run();
    expect((await signIn()).status).toBe(302);
    expect(await users()).toEqual([{ email: 'a@example.com', trial_started_at: '2026-01-01T00:00:00.000Z' }]);
  });

  it('refuses a state that does not match the cookie (an attacker’s code in the victim’s browser)', async () => {
    const go = await start();
    failedWith(await back(`code=x&state=${'A'.repeat(43)}`, jar(go)), 'Configuration');
    expect(token).not.toHaveBeenCalled();
    expect(await users()).toEqual([]);
  });

  it('refuses a callback without the OAuth cookie, with an expired or forged one, or without code or state', async () => {
    const go = await start();
    const state = new URL(go.headers.get('location')!).searchParams.get('state')!;
    const expired = await seal(SECRET, 'shepetal-oauth', { s: state, v: 'v'.repeat(43), n: '/account' }, 600, Date.now() - 601_000);
    const asSession = await seal(SECRET, 'shepetal-session', { s: state, v: 'v'.repeat(43), n: '/account' }, 600);
    for (const cookie of ['', `__Host-shepetal-oauth=${expired}`, `__Host-shepetal-oauth=${asSession}`, `__Host-shepetal-oauth=x${jar(go).split('=')[1]}`])
      failedWith(await back(`code=x&state=${state}`, cookie), 'Configuration');
    failedWith(await back(`state=${state}`, jar(go)), 'Configuration');
    failedWith(await back('code=x', jar(go)), 'Configuration');
    expect(token).not.toHaveBeenCalled();
  });

  it('sends a sign-in cancelled at Google back to the sign-in page', async () => {
    const go = await start();
    failedWith(await back('error=access_denied', jar(go)), 'AccessDenied');
    expect(token).not.toHaveBeenCalled();
  });

  it('refuses an email Google has not verified, or no email at all', async () => {
    for (const over of [{ email_verified: false }, { email_verified: undefined }, { email_verified: 'true' }, { email: undefined }, { email: '' }]) {
      google(jwt(claims(over)));
      failedWith(await signIn(), 'AccessDenied');
    }
    expect(await users()).toEqual([]);
  });

  it('refuses an id_token for another client or issuer, an expired one, or one that is not a JWT', async () => {
    for (const bad of [
      jwt(claims({ iss: 'https://evil.example' })),
      jwt(claims({ aud: 'other-client' })),
      jwt(claims({ aud: `evil${CLIENT}`, azp: undefined })), // a string that only contains the client id
      jwt(claims({ aud: [CLIENT, 'other-client'], azp: undefined })), // several audiences need azp
      jwt(claims({ aud: [CLIENT, 'other-client'], azp: 'other-client' })),
      jwt(claims({ azp: 'other-client' })),
      jwt(claims({ exp: nowS() - 1 })),
      jwt(claims({ exp: undefined })),
      jwt(claims({ iat: nowS() + 3600 })),
      'not-a-jwt',
      `${jwt(claims())}.extra`,
      null,
    ]) {
      google(bad);
      failedWith(await signIn(), 'Configuration');
    }
    expect(idTokenClaims(jwt(claims({ aud: [CLIENT, 'x'] })), CLIENT)).not.toBeNull();
    expect(idTokenClaims(jwt(claims({ iss: 'accounts.google.com' })), CLIENT)).not.toBeNull();
    expect(idTokenClaims(jwt(claims()), '')).toBeNull();
    expect(await users()).toEqual([]);
  });

  // A string aud is our client id or nothing (a substring match took 'evil' + clientId); a list must hold it AND come
  // with azp = our client, or a token Google issued to another client that merely lists ours would sign in here.
  it('aud: a string equal to the client id; a list with it only when azp is our client', () => {
    const ok = (over: object) => idTokenClaims(jwt(claims(over)), CLIENT) !== null;
    expect(ok({ aud: CLIENT, azp: undefined })).toBe(true);
    expect(ok({ aud: CLIENT })).toBe(true);
    for (const aud of [`evil${CLIENT}`, `${CLIENT}evil`, ` ${CLIENT}`, CLIENT.toUpperCase(), CLIENT.slice(0, -1), '', 0, null, {}, { [CLIENT]: 1 }])
      expect(ok({ aud, azp: undefined }), JSON.stringify(aud)).toBe(false);
    expect(ok({ aud: [CLIENT], azp: CLIENT })).toBe(true);
    expect(ok({ aud: [CLIENT, 'other'], azp: CLIENT })).toBe(true);
    for (const [aud, azp] of [[[CLIENT], undefined], [[CLIENT, 'other'], undefined], [[CLIENT], 'other'], [['other'], CLIENT], [[`evil${CLIENT}`], CLIENT], [[], CLIENT], [[[CLIENT]], CLIENT]])
      expect(ok({ aud, azp }), JSON.stringify([aud, azp])).toBe(false);
    expect(ok({ iss: 'https://accounts.google.com.evil' })).toBe(false);
    expect(ok({ iss: undefined })).toBe(false);
    expect(ok({ exp: nowS() - 1 })).toBe(false);
  });

  it('logs why a callback failed in a few fixed words, never the code, a token, the cookie or the email', async () => {
    const log = vi.spyOn(console, 'error').mockImplementation(() => {});
    const go = await start();
    failedWith(await back('code=4%2Fabc&state=wrong', jar(go)), 'Configuration');
    failedWith(await back('code=4%2Fabc&state=x'), 'Configuration');
    // An exception (D1 down, here with the email in its message) is the same 302, logged by class name only.
    vi.spyOn(await import('./account'), 'upsertUser').mockRejectedValue(new TypeError('D1 refused a@example.com ya29.secret'));
    failedWith(await signIn(), 'Configuration');
    const out = log.mock.calls.map((c) => c.join(' '));
    expect(out).toEqual([
      'google sign-in: Configuration (state mismatch)',
      'google sign-in: Configuration (no valid sign-in cookie)',
      'google sign-in: Configuration (exception TypeError)',
    ]);
    const cookie = jar(go).split('=')[1];
    for (const secret of ['4/abc', '4%2Fabc', cookie, 'a@example.com', 'A@Example.com', 'ya29', 'eyJ', 'google-client-secret', SECRET]) expect(out.join('\n')).not.toContain(secret);
  });

  it('logs a failed code exchange with the status only: no token, id_token or client secret', async () => {
    const log = vi.spyOn(console, 'error').mockImplementation(() => {});
    google(null, 400);
    failedWith(await signIn(), 'Configuration');
    google(jwt(claims({ aud: 'other-client' })));
    failedWith(await signIn(), 'Configuration');
    const out = JSON.stringify(log.mock.calls);
    expect(out).toContain('google sign-in: Configuration (token endpoint 400)');
    for (const secret of ['google-client-secret', 'ya29', 'eyJ', SECRET, '4/abc']) expect(out).not.toContain(secret);
  });

  it('returns only to a path on this site, whatever callbackUrl the sign-in started with', async () => {
    for (const evil of ['//evil.example', 'https://evil.example/', '/\\evil.example', '/\t/evil.example', '/\n/evil.example', '/..//evil.example', '/.//evil.example', 'evil.example']) {
      const res = await signIn(evil);
      expect(res.headers.get('location'), JSON.stringify(evil)).toBe(`${SITE_URL}/account`);
    }
    expect((await signIn('/%09/evil.example')).headers.get('location')).toBe(`${SITE_URL}/account`); // a tab once decoded
    expect((await signIn('/account#plans')).headers.get('location')).toBe(`${SITE_URL}/account#plans`);
  });

  // The id_token is trusted because it comes from Google's token endpoint over TLS: no setting may point that elsewhere
  // in production.
  it('uses the e2e’s fake token endpoint only in a local http run, on loopback', async () => {
    process.env.GOOGLE_TOKEN_URL = 'http://127.0.0.1:9/token';
    await signIn();
    expect(token.mock.calls[0][0]).toBe(GOOGLE_TOKEN); // https site: ignored
    process.env.AUTH_URL = 'http://localhost:3000';
    process.env.GOOGLE_TOKEN_URL = 'https://evil.example/token';
    await signIn();
    expect(token.mock.calls[1][0]).toBe(GOOGLE_TOKEN);
    process.env.GOOGLE_TOKEN_URL = 'http://127.0.0.1:9/token';
    const res = await signIn();
    expect(token.mock.calls[2][0]).toBe('http://127.0.0.1:9/token');
    // Local http: plain cookie names, no Secure, and the callback on AUTH_URL.
    expect(res.headers.get('location')).toBe('http://localhost:3000/account');
    expect(cookieOf(res, 'shepetal-session')).toMatch(/; Path=\/; Max-Age=2592000; HttpOnly; SameSite=Lax$/);
    expect(Object.fromEntries(new URLSearchParams((token.mock.calls[2][1] as RequestInit).body as URLSearchParams)).redirect_uri).toBe('http://localhost:3000/api/auth/callback/google');
  });
});

describe('the web session', () => {
  const sessionCookie = async (email = 'a@example.com', maxAge = 600, at = Date.now()) => `__Host-shepetal-session=${await seal(SECRET, 'shepetal-session', { e: email }, maxAge, at)}`;
  const req = (method: string, headers: Record<string, string>) => new Request(`${SITE_URL}/api/checkout`, { method, headers });

  it('signs out: a POST from the site clears the cookie and lands on /', async () => {
    expect((await signOutPost(req('POST', { origin: 'https://evil.example' }))).status).toBe(403);
    const res = await signOutPost(req('POST', { origin: ORIGIN }));
    expect([res.status, res.headers.get('location')]).toEqual([303, `${SITE_URL}/`]);
    expect(cookieOf(res, '__Host-shepetal-session')).toMatch(/^__Host-shepetal-session=; Path=\/; Max-Age=0; HttpOnly; SameSite=Lax; Secure$/);
  });

  it('refuses a forged, expired or foreign session', async () => {
    const cookie = await sessionCookie();
    expect(await sessionEmail(req('GET', { cookie }))).toBe('a@example.com');
    const oauth = `__Host-shepetal-session=${await seal(SECRET, 'shepetal-oauth', { e: 'a@example.com' }, 600)}`;
    const other = `__Host-shepetal-session=${await seal('another-secret', 'shepetal-session', { e: 'a@example.com' }, 600)}`;
    for (const bad of [await sessionCookie('a@example.com', 1, Date.now() - 5000), oauth, other, `${cookie.slice(0, -2)}xx`, `shepetal-session=${cookie.split('=')[1]}`])
      expect(await sessionEmail(req('GET', { cookie: bad })), bad).toBeNull();
  });

  it('requestUser: Bearer first, never the cookie beside a bad one; the cookie on a POST only from the site', async () => {
    const cookie = await sessionCookie();
    const bearer = await createToken((await upsertUser('app@example.com')).email);
    expect((await requestUser(req('POST', { authorization: `Bearer ${bearer}` })))?.email).toBe('app@example.com'); // the apps: no Origin
    expect(await requestUser(req('GET', { authorization: 'Bearer not-a-token', cookie }))).toBeNull();
    for (const malformed of ['Basic eDp4', 'Bearer', 'Bearer a b', ''])
      expect(await requestUser(req('GET', { authorization: malformed, cookie })), malformed).toBeNull();
    expect((await requestUser(req('GET', { cookie })))?.email).toBe('a@example.com');
    expect((await requestUser(req('POST', { cookie, origin: ORIGIN })))?.email).toBe('a@example.com');
    expect(await requestUser(req('POST', { cookie, origin: 'https://evil.example' }))).toBeNull();
    expect(await requestUser(req('POST', { cookie }))).toBeNull();
    expect(await requestUser(req('GET', {}))).toBeNull();
  });

  // A header that is there but not a valid Bearer is a client that meant to use a token: falling back to the cookie
  // would answer it as whoever is signed in to the browser. The route answers 401.
  it('a malformed or unknown Authorization header beside a valid cookie: the route answers 401', async () => {
    const { GET: account } = await import('@/app/api/account/route');
    const cookie = await sessionCookie();
    const get = (headers: Record<string, string>) => account(new Request(`${SITE_URL}/api/account`, { headers }));
    expect((await get({ cookie })).status).toBe(200);
    for (const authorization of ['', 'Basic eDp4', 'Bearer', 'Bearer ', 'Bearer a b', 'Bearer,x', 'Token abc', 'bearer-x', 'Bearer not-a-token', `Bearer ${cookie.split('=')[1]}`]) {
      const res = await get({ authorization, cookie });
      expect([res.status, await res.json()], JSON.stringify(authorization)).toEqual([401, { error: 'unauthorized' }]);
    }
  });

  it('a session for an email with no row creates it (as the old account page did)', async () => {
    expect((await requestUser(req('GET', { cookie: await sessionCookie('new@example.com') })))?.email).toBe('new@example.com');
    expect((await users()).map((u) => u.email)).toContain('new@example.com');
  });

  it('redirects /login signed in to ?next= (on this site), and /account signed out to the sign-in page', async () => {
    const cookie = await sessionCookie();
    const at = async (path: string, c = '') => {
      const res = await pageRedirect(new Request(`${SITE_URL}${path}`, { headers: { cookie: c } }), new URL(path, SITE_URL));
      return res && [res.status, res.headers.get('location'), res.headers.get('cache-control')];
    };
    expect(await at('/login', cookie)).toEqual([307, `${SITE_URL}/account`, 'private, no-store']);
    expect(await at('/login?next=%2Fapp%2Flogin%3Fstate%3Dx', cookie)).toEqual([307, `${SITE_URL}/app/login?state=x`, 'private, no-store']);
    // The signed-in 307 is where round 1's dot-segment bug became an open redirect: each lands on /account.
    for (const evil of ['%2F%09%2Fevil.example', '%2F.%2F%2Fevil.example', '%2F%5Cevil.example', '%2F%2Fevil.example', '%2F.%2F.%2F%2Fevil.example',
      '%2F..%2F%2Fevil.example', '%2F%252F%252Fevil.example', '%2F%25252F%25252Fevil.example', '%2F%255Cevil.example', '%2F%2509%2Fevil.example', 'https%3A%2F%2Fevil.example'])
      expect((await at(`/login?next=${evil}`, cookie))?.[1], evil).toBe(`${SITE_URL}/account`);
    expect(await at('/login?error=AccessDenied', cookie)).toBeNull(); // the failed line, not a loop
    expect(await at('/login')).toBeNull();
    expect(await at('/account', cookie)).toBeNull();
    expect(await at('/account?purchased=1')).toEqual([307, `${SITE_URL}/login?next=%2Faccount%3Fpurchased%3D1`, 'private, no-store']);
  });
});

it('answers /api/auth/providers as Auth.js did, built from the site URL', async () => {
  expect(await (await providers()).json()).toEqual({
    google: { id: 'google', name: 'Google', type: 'oidc', signinUrl: `${SITE_URL}/api/auth/signin/google`, callbackUrl: `${SITE_URL}/api/auth/callback/google` },
  });
  expect(siteUrl()).toBe(SITE_URL);
});
