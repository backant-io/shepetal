import { db } from './db';
import { createToken, randomSecret, sha256 } from './tokens';

// App sign-in: OAuth for native apps (RFC 8252) with PKCE (RFC 7636), see API.md.
export const CODE_TTL = 60; // seconds a one-time code lives

const CHALLENGE = /^[A-Za-z0-9_-]{43}$/; // base64url of 32 bytes, no padding
const VERIFIER = /^[A-Za-z0-9._~-]{43,128}$/; // RFC 7636 4.1
const iso = (ms: number) => new Date(ms).toISOString();

/**
 * The apps' redirect URIs, compared as strings and never parsed, so userinfo, fragments,
 * look-alike hosts and localhost never match: shepetal://auth, or http://127.0.0.1:<port>/callback.
 */
export function isAllowedRedirect(uri: string): boolean {
  if (uri === 'shepetal://auth') return true;
  const port = /^http:\/\/127\.0\.0\.1:([1-9]\d{0,4})\/callback$/.exec(uri)?.[1];
  return !!port && Number(port) <= 65535;
}

/** The S256 code_challenge of a verifier: base64url(SHA-256(verifier)) without padding. */
export async function s256(verifier: string): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier)));
  return btoa(String.fromCharCode(...d)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export type LoginRequest = { redirect_uri: string; state: string; code_challenge: string };

/** The GET /app/login query, or null when it gets a 400. */
export function parseLogin(q: URLSearchParams): LoginRequest | null {
  const redirect_uri = q.get('redirect_uri') ?? '';
  const state = q.get('state') ?? '';
  const code_challenge = q.get('code_challenge') ?? '';
  const valid =
    isAllowedRedirect(redirect_uri) &&
    state.length >= 1 &&
    state.length <= 512 &&
    CHALLENGE.test(code_challenge) &&
    q.get('code_challenge_method') === 'S256';
  return valid ? { redirect_uri, state, code_challenge } : null;
}

/** The /app/login query for a login request, in a fixed order. */
export const loginQuery = (r: LoginRequest) =>
  new URLSearchParams({ redirect_uri: r.redirect_uri, state: r.state, code_challenge: r.code_challenge, code_challenge_method: 'S256' }).toString();

/** What the consent page calls the app that asked. */
export const appKind = (redirectUri: string) => (redirectUri === 'shepetal://auth' ? 'Mac or iPhone app' : 'desktop app');

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

/**
 * The consent page /app/login shows to a signed-in user. A GET never issues a code: only this
 * form, posted back with its CSRF token, does.
 */
export function consentPage(email: string, r: LoginRequest, csrf: string): string {
  const fields = { redirect_uri: r.redirect_uri, state: r.state, code_challenge: r.code_challenge, code_challenge_method: 'S256', csrf };
  const inputs = Object.entries(fields)
    .map(([k, v]) => `<input type="hidden" name="${k}" value="${esc(v)}">`)
    .join('');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>Sign in to Shepetal</title></head>
<body style="font-family:system-ui,sans-serif;max-width:32rem;margin:6rem auto;padding:0 1rem;line-height:1.5">
<h1 style="font-size:1.5rem">Sign in to the Shepetal app on this computer as ${esc(email)}?</h1>
<p>The Shepetal ${appKind(r.redirect_uri)} asked to sign in. Continue only if you just chose Sign in in the app yourself.</p>
<form method="post" action="/app/login">${inputs}<button type="submit" style="font:inherit;padding:.6rem 1.4rem">Continue</button></form>
<p><a href="/app/login?${esc(loginQuery(r))}&amp;switch=1">Not you? Use another account</a></p>
</body></html>`;
}

/** A one-time code for `email` (an existing users row). Returns the redirect: <redirect_uri>?code=&state=. */
export async function issueCode(email: string, r: LoginRequest, now = Date.now()): Promise<string> {
  const code = randomSecret();
  await db().batch([
    db().prepare('DELETE FROM app_codes WHERE expires_at <= ?1').bind(iso(now)),
    db()
      .prepare('INSERT INTO app_codes (code_hash, email, code_challenge, redirect_uri, expires_at) VALUES (?1, ?2, ?3, ?4, ?5)')
      .bind(await sha256(code), email, r.code_challenge, r.redirect_uri, iso(now + CODE_TTL * 1000)),
  ]);
  // encodeURIComponent, not URLSearchParams: a space must come back as %20, not '+'.
  return `${r.redirect_uri}?code=${code}&state=${encodeURIComponent(r.state)}`;
}

/**
 * POST /api/app/token. The first redemption spends the code, right or wrong, so a code can
 * never be retried with other verifiers. Null is invalid_grant.
 */
export async function redeemCode(code: string, verifier: string, redirectUri: string, now = Date.now()) {
  const row = await db()
    .prepare('DELETE FROM app_codes WHERE code_hash = ?1 RETURNING email, code_challenge, redirect_uri, expires_at')
    .bind(await sha256(code))
    .first<{ email: string; code_challenge: string; redirect_uri: string; expires_at: string }>();
  if (!row || Date.parse(row.expires_at) <= now || row.redirect_uri !== redirectUri) return null;
  if (!VERIFIER.test(verifier) || (await s256(verifier)) !== row.code_challenge) return null;
  return { access_token: await createToken(row.email), email: row.email };
}
