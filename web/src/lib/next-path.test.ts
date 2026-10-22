import { describe, expect, it } from 'vitest';
import { safeNext } from './next-path';

// safeNext decides where the signed-in /login 307 and the Google callback send the browser. Round 1 resolved dot
// segments first and checked the input, so '/./' + '/evil.com' could come out as '//evil.com': an open redirect on the
// site's own domain. The result is what is checked now, and these tests check the result the way a browser, or any
// later code that decodes it once more, would read it.

const SITE = 'https://shepetal.app';
const EVIL = [
  '//evil.com', '/\\evil.com', '/%2F%2Fevil.com', '/%2f%2fevil.com', '/%2F/evil.com', '/%5Cevil.com', '/%5cevil.com',
  '/././/evil.com', '/..//evil.com', '/.//evil.com', '/a/..//evil.com', '/%2e%2e//evil.com', '/%2e//evil.com', '/.%2e//evil.com',
  '/./%2Fevil.com', '/a/../%2F%2Fevil.com', '/..%2F%2Fevil.com', '/.%2F%2Fevil.com', '/%2e%2F/evil.com', '/%252F%252Fevil.com',
  '/%25252F%25252Fevil.com', '/%255Cevil.com', '/%09/evil.com', '/%0a/evil.com', '/%0D/evil.com', '/%00/evil.com', '/%7f/evil.com',
  '/%C2%85/evil.com', '/\t/evil.com', '/\n/evil.com', '/\r/evil.com', '/\x00/evil.com', '/\x7f/evil.com', '/\u0085/evil.com',
  '/\\/evil.com', '\\\\evil.com', '/%E0%A4%A', 'https://evil.com', 'http:evil.com', '//evil.com/account', '///evil.com',
  ' /evil.com', 'evil.com', '', '.', '..', './/evil.com', 'javascript:alert(1)', '/%2e%2e%2f%2fevil.com', '/%2e%2e/%2e%2e//evil.com',
];

/** What a browser follows after a 307 to `path` on the site, and what code that decodes it once more would follow. */
function lands(path: string): string[] {
  const u = new URL(path, SITE);
  let once = path;
  try {
    once = decodeURIComponent(u.pathname) + u.search + u.hash;
  } catch {}
  return [u.origin, new URL(once.replace(/\\/g, '/').replace(/[\t\n\r]/g, ''), SITE).origin];
}

/** A small seeded PRNG, so a failure reproduces. */
function rng(seed: number) {
  return () => ((seed = (seed * 1103515245 + 12345) >>> 0) / 2 ** 32);
}

describe('safeNext', () => {
  it('sends every way of writing another site to /account', () => {
    for (const bad of EVIL) expect(safeNext(bad), JSON.stringify(bad)).toBe('/account');
    expect(safeNext(undefined)).toBe('/account');
    expect(safeNext(null)).toBe('/account');
  });

  it('keeps a real path on this site, with its query and fragment (the apps encode their redirect_uri there)', () => {
    for (const ok of ['/account', '/account#plans', '/account?purchased=1#plans', '/app/login?redirect_uri=http%3A%2F%2F127.0.0.1%3A5000%2Fcallback&state=x', '/changelog', '/a/b/../c', '/%C3%A9t%C3%A9'])
      expect(lands(safeNext(ok)), ok).toEqual([SITE, SITE]);
    expect(safeNext('/a/b/../c')).toBe('/a/c'); // resolved, then checked
    expect(safeNext('/account#plans')).toBe('/account#plans');
    expect(safeNext('/app/login?redirect_uri=http%3A%2F%2F127.0.0.1%3A5000%2Fcallback')).toBe('/app/login?redirect_uri=http%3A%2F%2F127.0.0.1%3A5000%2Fcallback');
  });

  it('fuzz: whatever it returns is a single-slash path that stays on this site, read once or decoded again', () => {
    const parts = ['/', '//', '\\', '.', '..', '%2e', '%2E', '%2f', '%2F', '%5c', '%5C', '%25', '%252f', '%09', '%0a', '%00', '\t', '\n', 'evil.com', 'a', '@', ':', '?', '#', '%3F', '%23', ' ', '%20', 'https:', '%C2%85'];
    const next = rng(290);
    for (let i = 0; i < 20000; i++) {
      let s = '/';
      for (let n = 1 + Math.floor(next() * 7); n > 0; n--) s += parts[Math.floor(next() * parts.length)];
      const out = safeNext(s);
      if (out === '/account') continue;
      expect(out.startsWith('/') && !out.startsWith('//') && !out.startsWith('/\\'), JSON.stringify([s, out])).toBe(true);
      expect(lands(out), JSON.stringify([s, out])).toEqual([SITE, SITE]);
      expect(safeNext(out), JSON.stringify([s, out])).toBe(out); // stable: a second pass changes nothing
    }
  });
});
