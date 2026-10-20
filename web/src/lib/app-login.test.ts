import { describe, expect, it, vi } from 'vitest';
import { upsertUser } from './account';
import { CODE_TTL, isAllowedRedirect, issueCode, parseLogin, redeemCode, s256 } from './app-login';
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
  it('accepts the contract', () => expect(parseLogin(q())).toEqual({ redirect_uri: MAC, state: 'st', code_challenge: CHALLENGE }));
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
    const raw = await issueCode((await upsertUser('a@example.com')).email, { redirect_uri: MAC, state, code_challenge: CHALLENGE }, T);
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

  it(`expires after ${CODE_TTL} s`, async () => {
    const a = await login();
    expect(await redeemCode(a.code, VERIFIER, MAC, T + CODE_TTL * 1000 - 1)).not.toBeNull();
    const b = await login();
    expect(await redeemCode(b.code, VERIFIER, MAC, T + CODE_TTL * 1000)).toBeNull();
  });

  it('refuses an unknown code', async () => {
    expect(await redeemCode('nope', VERIFIER, MAC, T)).toBeNull();
  });
});
