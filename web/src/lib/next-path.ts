const BASE = 'https://next.invalid';
const FALLBACK = '/account';
// Control characters (C0, DEL, C1) and the backslash, which browsers read as '/' in a path ('/\evil.com' is '//evil.com').
const BAD = /[\x00-\x1f\x7f-\x9f\\]/;

/** The path decoded until it no longer changes (%252F is %2F is '/'), or null when it does not decode. */
function decoded(path: string): string | null {
  for (let i = 0; i < 4; i++) {
    let next: string;
    try {
      next = decodeURIComponent(path);
    } catch {
      return null;
    }
    if (next === path) return path;
    path = next;
  }
  return null; // still changing after 4 rounds: nothing a link of ours would send
}

/** A path on this site: one '/', then no second '/' or '\', and no control character, encoded or not, in the path. */
function sameOriginPath(pathname: string): boolean {
  const plain = decoded(pathname);
  return (
    plain !== null &&
    pathname.startsWith('/') &&
    !pathname.startsWith('//') &&
    !BAD.test(pathname) &&
    // Decoded, the path may hold no control character or backslash, and no '/' where the raw path has an encoded one.
    !BAD.test(plain) &&
    !/%(25)*(2f|5c)/i.test(pathname) &&
    !plain.startsWith('//')
  );
}

/**
 * Where a sign-in may return to: a path on this site, never another origin. Anything else is the account page.
 * The input must start with a single '/' and hold no control character or backslash; it is then resolved the way a
 * browser resolves a Location (dot segments, %2e), and the RESULT is checked again: one leading '/', and in the path,
 * after decoding, no second '/' at the start, no backslash, no control character and no encoded slash or backslash
 * ('/%2F%2Fevil.com', '/..//evil.com', '/%09/evil.com' are all the account page). The query and fragment stay as they
 * were sent (the apps' redirect_uri is percent-encoded there) and cannot change the origin once the path is safe.
 */
export function safeNext(next: string | undefined | null): string {
  if (typeof next !== 'string' || !next.startsWith('/') || next.startsWith('//') || BAD.test(next)) return FALLBACK;
  let u: URL;
  try {
    u = new URL(next, BASE);
  } catch {
    return FALLBACK;
  }
  if (u.origin !== BASE || !sameOriginPath(u.pathname)) return FALLBACK;
  const path = u.pathname + u.search + u.hash;
  // The result resolves to itself, on this origin: what the browser follows is what was checked.
  const again = new URL(path, BASE);
  return again.origin === BASE && again.pathname === u.pathname && !BAD.test(path) ? path : FALLBACK;
}
