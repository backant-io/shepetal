import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { hostRedirect, LEGACY_HOST, SHEPETAL_DOMAIN, SITE_URL } from './site';

const at = (host: string, path: string) => hostRedirect(new URL(`https://${host}${path}`));
const moved = (r: Response | null) => r && [r.status, r.headers.get('location')];

describe('the one domain', () => {
  it('comes from wrangler.toml [vars] SHEPETAL_DOMAIN, https only', () => {
    expect(SHEPETAL_DOMAIN).toBe('shepetal.app');
    expect(SITE_URL).toBe('https://shepetal.app');
  });

  it('is what wrangler.toml attaches: the domain, its www and the old host, and no other host is hard-coded', () => {
    const toml = readFileSync(new URL('../../wrangler.toml', import.meta.url), 'utf8');
    const routes = [...toml.matchAll(/pattern = "([^"]+)", custom_domain = true/g)].map((m) => m[1]);
    expect(routes).toEqual([SHEPETAL_DOMAIN, `www.${SHEPETAL_DOMAIN}`, LEGACY_HOST]);
    expect(toml).not.toMatch(/^(AUTH_URL|NEXTAUTH_URL)\s*=/m);
  });

});

describe('hosts', () => {
  it('serves everything on the domain itself, on workers.dev previews and on localhost', () => {
    for (const host of [SHEPETAL_DOMAIN, 'cc5b28db-shepetal-web.business-c0d.workers.dev', 'localhost:8787'])
      for (const path of ['/', '/account', '/app/login?state=x', '/appcast.xml', '/api/license']) expect(at(host, path)).toBeNull();
  });

  it('sends www to the apex with a 301, keeping the path and query', () => {
    expect(moved(at(`www.${SHEPETAL_DOMAIN}`, '/'))).toEqual([301, `${SITE_URL}/`]);
    expect(moved(at(`www.${SHEPETAL_DOMAIN}`, '/terms?x=1'))).toEqual([301, `${SITE_URL}/terms?x=1`]);
    expect(moved(at(`www.${SHEPETAL_DOMAIN}`, '/api/license'))).toEqual([301, `${SITE_URL}/api/license`]);
  });

  // The old host is no longer a site: nothing answers there, so nothing (the Stripe webhook included) can keep
  // depending on it unnoticed.
  it('moves every path on the old host, /api/* included, to the same path and query on the domain with a 301', () => {
    const q = '?redirect_uri=shepetal%3A%2F%2Fauth&state=a%20b&code_challenge=xyz&code_challenge_method=S256';
    expect(moved(at(LEGACY_HOST, `/app/login${q}`))).toEqual([301, `${SITE_URL}/app/login${q}`]);
    expect(moved(at(LEGACY_HOST, '/api/license?v=0.2.2'))).toEqual([301, `${SITE_URL}/api/license?v=0.2.2`]);
    for (const path of ['/', '/account', '/login', '/privacy', '/download', '/apiary', '/appcast.xml', '/api', '/api/license', '/api/checkout',
      '/api/app/token', '/api/app/revoke', '/api/billing/portal', '/api/stripe/webhook', '/api/auth/session', '/api/auth/callback/google'])
      expect(moved(at(LEGACY_HOST, path))).toEqual([301, `${SITE_URL}${path}`]);
  });
});
