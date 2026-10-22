const BASE = 'https://next.invalid';

/**
 * Where a sign-in may return to: a path on this site, never another origin. Anything else is the account page.
 * Parsed the way a browser resolves a Location: control characters and backslashes are refused ('/\t/evil.com' is
 * '//evil.com' to a browser), and so is a path that dot segments turn into '//evil.com'. Path, query and fragment.
 */
export function safeNext(next: string | undefined | null): string {
  if (!next || !next.startsWith('/') || /[\x00-\x1f\x7f\\]/.test(next)) return '/account';
  const u = new URL(next, BASE);
  const path = u.pathname + u.search + u.hash;
  return u.origin === BASE && !path.startsWith('//') ? path : '/account';
}
