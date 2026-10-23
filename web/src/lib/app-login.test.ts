import { describe, expect, it, vi } from 'vitest';
import { upsertUser } from './account';
import { CODE_TTL, consentPage, isAllowedRedirect, issueCode, parseLogin, redeemCode, s256 } from './app-login';
import { db } from './db';
import { useTestDb } from './test-db';
import { userForToken } from './tokens';

vi.mock('./db', () => import('./test-db'));
useTestDb();

const T = Date.parse('2026-01-01T00:00:00.000Z');
// RFC 7636 appendix B
const VERIFIER = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
const CHALLENGE = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
const MAC = 'shepetal://auth';

async function login(redirect_uri = MAC, state = 'st') {
  const { email } = await upsertUser('a@example.com');
  const to = new URL(await issueCode(email, { redirect_uri, state, code_challenge: CHALLENGE }, T));
  return { to, code: to.searchParams.get('code')! };
}

it('computes the S256 challenge of RFC 7636 appendix B', async () => {
  expect(await s256(VERIFIER)).toBe(CHALLENGE);
});

describe('redirect_uri allowlist', () => {
  it.each([MAC, 'http://127.0.0.1:1/callback', 'http://127.0.0.1:53682/callback', 'http://127.0.0.1:65535/callback'])(
    'allows %s',
    (uri) => expect(isAllowedRedirect(uri)).toBe(true),
  );

  // Anything a parser might read as one of the above, or that sends the code elsewhere.
  it.each([
    'shepetal://auth.evil',
    'shepetal://auth/',
    'shepetal://auth?x=1',
    'shepetal://auth#x',
    'shepetal://evil',
    'SHEPETAL://auth',
    'shepetal:auth',
    'http://127.0.0.1.evil.com/callback',
    'http://127.0.0.1.evil.com:8080/callback',
    'http://localhost:8080/callback',
    'http://user@127.0.0.1:8080/callback',
    'http://127.0.0.1:8080@evil.com/callback',
    'http://127.0.0.1:8080/callback#x',
    'http://127.0.0.1:8080/callback?next=https://evil.com',
    'http://127.0.0.1:8080/callback/',
    'http://127.0.0.1:8080/callback/../evil',
    'http://127.0.0.1:8080/Callback',
    'https://127.0.0.1:8080/callback',
    'http://127.0.0.1/callback',
    'http://127.0.0.1:0/callback',
    'http://127.0.0.1:65536/callback',
    'http://127.0.0.1:08080/callback',
    'http://127.1:8080/callback',
    'http://[::1]:8080/callback',
    'http://127.0.0.2:8080/callback',
    ' shepetal://auth',
    'shepetal://auth\n',
    '',
  ])('rejects %j', (uri) => expect(isAllowedRedirect(uri)).toBe(false));
});

describe('GET /app/login query', () => {
  const q = (over: Record<string, string | null> = {}) => {
    const p = { redirect_uri: MAC, state: 'st', code_challenge: CHALLENGE, code_challenge_method: 'S256', ...over };
    return new URLSearchParams(Object.entries(p).filter(([, v]) => v !== null) as [string, string][]);
  };
  it('accepts the contract', () =>
    expect(parseLogin(q())).toEqual({ redirect_uri: MAC, state: 'st', code_challenge: CHALLENGE }));
  it.each<Record<string, string | null>>([
    { redirect_uri: 'shepetal://auth.evil' },
    { redirect_uri: null },
    { code_challenge_method: 'plain' },
    { code_challenge_method: null },
    { code_challenge: VERIFIER.slice(1) },
    { code_challenge: CHALLENGE + '=' },
    { code_challenge: null },
    { state: '' },
    { state: null },
    { state: 'x'.repeat(513) },
  ])('rejects %j', (over) => expect(parseLogin(q(over))).toBeNull());
});

describe('code and PKCE', () => {
  it('redirects with a one-time code and the state unchanged', async () => {
    const state = 'a b&c=d/é+%?#';
    const raw = await issueCode(
      (await upsertUser('a@example.com')).email,
      { redirect_uri: MAC, state, code_challenge: CHALLENGE },
      T,
    );
    expect(raw).toMatch(/^shepetal:\/\/auth\?code=[A-Za-z0-9_-]{43}&state=a%20b%26c%3Dd%2F%C3%A9%2B%25%3F%23$/);
    expect(new URL(raw).searchParams.get('state')).toBe(state);
  });

  it('stores only the SHA-256 of the code', async () => {
    const { code } = await login();
    expect(JSON.stringify((await db().prepare('SELECT * FROM app_codes').all()).results)).not.toContain(code);
  });

  it('gives a working token for the right verifier and redirect_uri', async () => {
    const { code } = await login();
    const r = await redeemCode(code, VERIFIER, MAC, T + 1000);
    expect(r).toEqual({ access_token: expect.stringMatching(/^[A-Za-z0-9_-]{43}$/), email: 'a@example.com' });
    expect((await userForToken(r!.access_token))?.email).toBe('a@example.com');
  });

  it('works for the loopback redirect too', async () => {
    const uri = 'http://127.0.0.1:53682/callback';
    const { to, code } = await login(uri);
    expect(to.origin + to.pathname).toBe(uri);
    expect(await redeemCode(code, VERIFIER, uri, T)).not.toBeNull();
  });

  it('refuses a wrong verifier, and the code is spent by the try', async () => {
    const { code } = await login();
    expect(await redeemCode(code, VERIFIER.replace('d', 'e'), MAC, T)).toBeNull();
    expect(await redeemCode(code, VERIFIER, MAC, T)).toBeNull();
  });

  it('refuses a verifier outside RFC 7636 even if it hashes right', async () => {
    const short = 'abc';
    const { email } = await upsertUser('a@example.com');
    const to = new URL(await issueCode(email, { redirect_uri: MAC, state: 's', code_challenge: await s256(short) }, T));
    expect(await redeemCode(to.searchParams.get('code')!, short, MAC, T)).toBeNull();
  });

  it('refuses a redirect_uri other than the one the code was issued for', async () => {
    const { code } = await login(MAC);
    expect(await redeemCode(code, VERIFIER, 'http://127.0.0.1:53682/callback', T)).toBeNull();
  });

  it('is single use', async () => {
    const { code } = await login();
    expect(await redeemCode(code, VERIFIER, MAC, T)).not.toBeNull();
    expect(await redeemCode(code, VERIFIER, MAC, T)).toBeNull();
  });

  // API.md: 60 s, written out so a longer CODE_TTL fails here.
  it('expires after 60 s', async () => {
    expect(CODE_TTL).toBe(60);
    const a = await login();
    expect(await redeemCode(a.code, VERIFIER, MAC, T + 60_000 - 1)).not.toBeNull();
    const b = await login();
    expect(await redeemCode(b.code, VERIFIER, MAC, T + 60_000)).toBeNull();
  });

  it('refuses an unknown code', async () => {
    expect(await redeemCode('nope', VERIFIER, MAC, T)).toBeNull();
  });
});

describe('consent page', () => {
  const r = { redirect_uri: MAC, state: '"><script>x</script>', code_challenge: CHALLENGE };

  it('asks before signing the app in, and names the kind of app', () => {
    const html = consentPage('a@example.com', r, 'csrf-1');
    expect(html).toContain('<h1>Sign in to the shepetal app?</h1>');
    expect(html).toContain('As a@example.com');
    expect(html).toContain('The Mac or iPhone app on this computer');
    expect(consentPage('a@example.com', { ...r, redirect_uri: 'http://127.0.0.1:53682/callback' }, 'c')).toContain(
      'desktop app',
    );
    expect(html).toContain('<form method="post" action="/app/login">');
    expect(html).toContain('<input type="hidden" name="csrf" value="csrf-1">');
    expect(html).toContain('Not you? Use another account');
  });

  // The account email is collected here (GDPR Art. 13: inform at collection), and § 312k BGB wants the cancel button
  // on every page of the site.
  it('links the Privacy Policy and the cancellation button', () => {
    const html = consentPage('a@example.com', r, 'c');
    expect(html).toContain('<a href="/privacy">Privacy</a>');
    expect(html).toContain('<a href="/cancel" lang="de">Verträge hier kündigen</a>');
  });

  // The trial emails need consent (§ 7 UWG, Art. 6(1)(a) GDPR): asked here, where the app creates the account, unticked.
  it('asks for the trial emails with an unticked box and a link to what they are', () => {
    const html = consentPage('a@example.com', r, 'c');
    expect(html).toContain(
      '<label class="check"><input type="checkbox" name="trial_emails" value="yes"> Send me three short emails about my trial. <a href="/privacy#trial-emails">Privacy</a></label><button type="submit">Continue</button></form>',
    );
    expect(html).not.toMatch(/checked/);
  });

  // state and email come from outside: they must never become markup.
  it('escapes what it echoes', () => {
    const html = consentPage('<b>@example.com', r, 'c');
    expect(html).not.toContain('<script>');
    expect(html).not.toContain('<b>@');
    expect(html).toContain('value="&#34;&#62;&#60;script&#62;x&#60;/script&#62;"');
  });
});

// The route itself (answered by worker.ts): a code only for the user who pressed Continue on this site, for the
// account the page showed. Status order as API.md: 400, then 403, then 401, then 302.
describe('/app/login route', async () => {
  const { GET, POST } = await import('@/app/app/login/route');
  const { seal } = await import('./session');
  const SITE = 'https://shepetal.app';
  process.env.AUTH_SECRET = 'app-login-test-secret';
  const q = new URLSearchParams({ redirect_uri: MAC, state: 'a b', code_challenge: CHALLENGE, code_challenge_method: 'S256' });
  const session = async (email = 'a@example.com') => `__Host-shepetal-session=${await seal('app-login-test-secret', 'shepetal-session', { e: email }, 600)}`;
  const codes = async () => (await db().prepare('SELECT count(*) AS n FROM app_codes').first<{ n: number }>())!.n;
  /** The consent page for `email`, then its form posted back as a browser would. */
  async function consent(email: string, { origin = SITE as string | null, csrf = undefined as string | undefined, as = email, fields = q } = {}) {
    const page = await GET(new Request(`${SITE}/app/login?${q}`, { headers: { cookie: await session(email) } }));
    expect(page.status).toBe(200);
    const kept = page.headers.get('set-cookie')!;
    expect(kept).toMatch(/^__Host-app-login-csrf=[^;]+; Path=\/; Max-Age=600; HttpOnly; SameSite=Lax; Secure$/);
    const sent = (await page.text()).match(/name="csrf" value="([^"]+)"/)![1];
    const body = new URLSearchParams(fields);
    body.set('csrf', csrf ?? sent);
    const cookie = [kept.split(';')[0], as && (await session(as))].filter(Boolean).join('; ');
    return POST(new Request(`${SITE}/app/login`, { method: 'POST', body, headers: { cookie, ...(origin && { origin }), 'content-type': 'application/x-www-form-urlencoded' } }));
  }

  it('GET: 400 for a bad query, Google with state and PKCE when signed out, the consent page signed in', async () => {
    expect((await GET(new Request(`${SITE}/app/login?redirect_uri=https%3A%2F%2Fevil.example`))).status).toBe(400);
    const out = await GET(new Request(`${SITE}/app/login?${q}`));
    expect(out.status).toBe(307);
    const google = new URL(out.headers.get('location')!);
    expect(google.searchParams.get('redirect_uri')).toBe(`${SITE}/api/auth/callback/google`);
    expect(google.searchParams.get('code_challenge_method')).toBe('S256');
    expect(out.headers.get('set-cookie')).toMatch(/^__Host-shepetal-oauth=/);
    const chooser = await GET(new Request(`${SITE}/app/login?${q}&switch=1`, { headers: { cookie: await session() } }));
    expect([chooser.status, new URL(chooser.headers.get('location')!).searchParams.get('prompt')]).toEqual([307, 'select_account']);
    expect(await codes()).toBe(0);
  });

  it('POST: Continue on this site is a 302 to the app with a code and the state', async () => {
    const res = await consent('a@example.com');
    expect(res.status).toBe(302);
    expect(res.headers.get('location')).toMatch(/^shepetal:\/\/auth\?code=[A-Za-z0-9_-]{43}&state=a%20b$/);
    expect(res.headers.get('set-cookie')).toMatch(/^__Host-app-login-csrf=; Path=\/; Max-Age=0;/);
  });

  it('POST: 400, then 403 (CSRF, Origin, another account than the page showed), then 401; no code issued', async () => {
    const bad = new URLSearchParams(q);
    bad.set('redirect_uri', 'https://evil.example/callback');
    expect((await consent('a@example.com', { fields: bad, origin: 'https://evil.example' })).status).toBe(400);
    expect((await consent('a@example.com', { csrf: 'A'.repeat(43) })).status).toBe(403); // same length, wrong value
    expect((await consent('a@example.com', { csrf: '' })).status).toBe(403);
    expect((await consent('a@example.com', { origin: 'https://evil.example' })).status).toBe(403);
    expect((await consent('a@example.com', { origin: null })).status).toBe(403);
    expect((await consent('a@example.com', { as: 'b@example.com' })).status).toBe(403); // signed in as someone else since
    expect((await consent('a@example.com', { as: '' })).status).toBe(401);
    expect(await codes()).toBe(0);
  });

  // The consent page's trial emails box (lib/trial-emails.ts): only a tick, posted with Continue, records the opt-in.
  it('POST: Continue unticked records no trial emails opt-in, ticked records its time; a refused POST records nothing', async () => {
    const optIn = async (email: string) => (await db().prepare('SELECT trial_emails_at FROM users WHERE email = ?1').bind(email).first<{ trial_emails_at: string | null }>())?.trial_emails_at;
    expect((await consent('quiet@example.com')).status).toBe(302);
    expect(await optIn('quiet@example.com')).toBeNull();
    const ticked = new URLSearchParams(q);
    ticked.set('trial_emails', 'yes');
    expect((await consent('loud@example.com', { fields: ticked, origin: 'https://evil.example' })).status).toBe(403);
    expect(await optIn('loud@example.com')).toBeUndefined(); // no user row either
    expect((await consent('loud@example.com', { fields: ticked })).status).toBe(302);
    expect(await optIn('loud@example.com')).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
  });
});
