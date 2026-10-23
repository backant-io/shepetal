import { afterEach, describe, expect, it, vi } from 'vitest';
import { GET as account } from '@/app/api/account/route';
import { securityHeaders } from '../../security-headers.mjs';
import { guarded, secured } from './native';
import { seal } from './session';
import { SITE_URL } from './site';
import { useTestDb } from './test-db';

vi.mock('./db', () => import('./test-db'));
useTestDb();

// worker.ts answers the native routes itself. An exception there used to reach Cloudflare, which answers its 1101
// page: a 500 that names the Worker, carries none of the site's headers and may be cached by nobody's rules. It is
// the site's own 500 now, with no stack or message in it, and a log line that names the route and the class only.

afterEach(() => {
  vi.restoreAllMocks();
  process.env.AUTH_SECRET = 'native-test-secret';
});

const expectSecured = (res: Response) => {
  for (const { key, value } of securityHeaders()) expect(res.headers.get(key), key).toBe(value);
};

describe('an exception in a native route', () => {
  it('is a 500 of the site’s own: JSON for an API, no stack or message, no-store, the security headers', async () => {
    const log = vi.spyOn(console, 'error').mockImplementation(() => {});
    const res = await guarded('GET /api/account', true, async () => {
      throw new TypeError('D1 said no for a@example.com with token sk_live_123');
    });
    expect(res.status).toBe(500);
    expect(res.headers.get('cache-control')).toBe('no-store');
    expectSecured(res);
    const body = await res.text();
    expect(JSON.parse(body)).toEqual({ error: 'server_error' });
    expect(log.mock.calls.map((c) => c.join(' '))).toEqual(['GET /api/account: 500 (TypeError)']);
    for (const leak of ['a@example.com', 'sk_live', 'D1 said', 'at ', '.ts']) {
      expect(body).not.toContain(leak);
      expect(JSON.stringify(log.mock.calls)).not.toContain(leak);
    }
  });

  it('on a page is a plain-text 500, and a thrown non-Error is logged by its type', async () => {
    const log = vi.spyOn(console, 'error').mockImplementation(() => {});
    const res = await guarded('GET page', false, () => Promise.reject('a@example.com'));
    expect([res.status, res.headers.get('content-type'), res.headers.get('cache-control')]).toEqual([500, 'text/plain; charset=utf-8', 'no-store']);
    expectSecured(res);
    expect(await res.text()).not.toContain('a@example.com');
    expect(log.mock.calls.map((c) => c.join(' '))).toEqual(['GET page: 500 (string)']);
  });

  it('a real one: GET /api/account with a session cookie but no AUTH_SECRET (unseal fails loud) is that 500', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    process.env.AUTH_SECRET = 'native-test-secret';
    const cookie = `__Host-shepetal-session=${await seal('native-test-secret', 'shepetal-session', { e: 'a@example.com' }, 600)}`;
    delete process.env.AUTH_SECRET;
    const req = new Request(`${SITE_URL}/api/account`, { headers: { cookie } });
    await expect(account(req)).rejects.toThrow(/AUTH_SECRET/); // what Cloudflare would have turned into a 1101
    const res = await guarded('GET /api/account', true, () => account(req));
    expect([res.status, await res.json()]).toEqual([500, { error: 'server_error' }]);
    expectSecured(res);
  });

  it('leaves an answer alone otherwise, adding the security headers to a copy (redirect headers are immutable)', async () => {
    const res = await guarded('GET /api/billing/portal', true, async () => secured(Response.redirect('https://billing.stripe.com/p/x', 303)));
    expect([res.status, res.headers.get('location')]).toEqual([303, 'https://billing.stripe.com/p/x']);
    expectSecured(res);
  });
});
