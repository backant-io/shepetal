/** Where a sign-in may return to: a path on this site, never another origin. Anything else is the account page. */
export function safeNext(next: string | undefined | null): string {
  if (!next || !next.startsWith('/') || next.startsWith('//') || next.includes('\\')) return '/account';
  return next;
}
