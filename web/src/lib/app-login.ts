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

// The consent page in the site's system (src/styles/system.css and site.css): concrete-white ground, ink, the
// Bodoni Moda wordmark, the small fn key, and one orange action. A route handler answers it, so it carries its own CSS.
const CONSENT_CSS = `@font-face{font-family:Archivo;font-weight:400 600;font-display:swap;src:url(/fonts/archivo-latin.woff2) format('woff2')}
@font-face{font-family:'Bodoni Moda';font-style:italic;font-weight:400 500;font-display:swap;src:url(/fonts/bodoni-moda-italic-latin.woff2) format('woff2')}
@font-face{font-family:'Fragment Mono';font-display:swap;src:url(/fonts/fragment-mono-latin.woff2) format('woff2')}
:root{--u:min(1vw,1.6vh);--gut:clamp(1rem,calc(3.4*var(--u)),6rem);color-scheme:light}
*,*::before,*::after{box-sizing:border-box}
html,body{margin:0;background:#E6E4DE}
body{min-height:100vh;display:flex;flex-direction:column;padding:0 var(--gut);color:#161512;font-family:Archivo,'Helvetica Neue',Arial,sans-serif;-webkit-font-smoothing:antialiased}
header{padding:1.6rem 0}
.mark{font:italic 500 1.9rem/1 'Bodoni Moda',Didot,serif;color:#161512;text-decoration:none;letter-spacing:-.01em}
main{flex:1;display:grid;grid-template-columns:minmax(0,56fr) minmax(0,44fr);column-gap:4rem;row-gap:2.5rem;align-items:start;padding-top:calc(10.5*var(--u) - 4.7rem)}
h1{margin:0;font-weight:520;font-size:clamp(2.5rem,calc(5.3*var(--u)),10rem);line-height:.97;letter-spacing:-.043em;text-wrap:balance}
.key{display:block;width:clamp(3.25rem,calc(6*var(--u)),12rem);height:auto;margin-top:calc(3.4*var(--u))}
.side{display:grid;row-gap:1.6rem;justify-items:start}
.mono{font-family:'Fragment Mono',ui-monospace,Menlo,monospace;font-size:.75rem;letter-spacing:.01em;line-height:1.45;color:#57544E}
.as{margin:0;font-size:clamp(1.2rem,calc(1.9*var(--u)),3.2rem);font-weight:520;line-height:1.2;letter-spacing:-.02em;overflow-wrap:anywhere}
.small{margin:0;font-size:1rem;line-height:1.5;color:#57544E;max-width:28rem}
form{margin:0}
button{display:inline-flex;align-items:center;font:inherit;font-weight:600;font-size:1.0625rem;letter-spacing:-.005em;padding:1.1rem 1.6rem;border:0;border-radius:4px;cursor:pointer;background:#FF4F12;color:#161512;box-shadow:inset 0 1px 0 rgba(255,255,255,.25),0 4px 0 #9a2f08,0 9px 14px -6px rgba(154,47,8,.5)}
button:hover{background:#ff5f28}button:active{transform:translateY(3px)}
a{color:#161512}
a:focus-visible,button:focus-visible{outline:2px solid #FF4F12;outline-offset:3px}
@media (max-width:760px){main{grid-template-columns:minmax(0,1fr);padding-top:3rem}h1{font-size:clamp(2.2rem,calc(10.4*var(--u)),6rem)}}`;

/**
 * The consent page /app/login shows to a signed-in user. A GET never issues a code: only this
 * form, posted back with its CSRF token, does.
 */
export function consentPage(email: string, r: LoginRequest, csrf: string): string {
  const fields = { redirect_uri: r.redirect_uri, state: r.state, code_challenge: r.code_challenge, code_challenge_method: 'S256', csrf };
  const inputs = Object.entries(fields)
    .map(([k, v]) => `<input type="hidden" name="${k}" value="${esc(v)}">`)
    .join('');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>Sign in to the shepetal app</title><link rel="icon" href="/favicon.svg" type="image/svg+xml"><style>${CONSENT_CSS}</style></head>
<body><header><a class="mark" href="/">shepetal</a></header>
<main><div><h1>Sign in to the shepetal app?</h1><img class="key" src="/brand/fn-key.svg" alt="" width="104" height="74"></div>
<div class="side"><span class="mono">The ${appKind(r.redirect_uri)} on this computer</span>
<p class="as">As ${esc(email)}</p>
<p class="small">Continue if you just chose Sign in in the app yourself.</p>
<form method="post" action="/app/login">${inputs}<button type="submit">Continue</button></form>
<a class="mono" href="/app/login?${esc(loginQuery(r))}&amp;switch=1">Not you? Use another account</a></div></main>
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
