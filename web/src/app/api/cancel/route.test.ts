import { beforeEach, describe, expect, it, vi } from 'vitest';

const cf = vi.hoisted(() => ({
  limit: vi.fn(async (_: { key: string }) => ({ success: true })),
  waitUntil: vi.fn((_: Promise<unknown>) => {}),
}));
vi.mock('@opennextjs/cloudflare', () => ({
  getCloudflareContext: () => ({ env: { CANCEL_LIMIT: { limit: cf.limit } }, ctx: { waitUntil: cf.waitUntil } }),
}));
const work = vi.hoisted(() => ({ processDeclaration: vi.fn((_: unknown) => new Promise<void>(() => {})) }));
vi.mock('@/lib/cancel', async (real) => ({ ...(await real<typeof import('@/lib/cancel')>()), ...work }));

const { POST } = await import('./route');

const SITE = 'https://shepetal.app';
const press = (fields: Record<string, string>, headers: Record<string, string> = { origin: SITE }) =>
  POST(new Request(`${SITE}/api/cancel`, { method: 'POST', headers: { 'cf-connecting-ip': '203.0.113.9', ...headers }, body: new URLSearchParams(fields) }));

beforeEach(() => vi.clearAllMocks());

describe('POST /api/cancel', () => {
  // The lookup, Stripe, D1 and the emails take longer for a subscriber than for an unknown email. Done before the
  // answer, the time it took would tell anyone which emails have a subscription.
  it('answers with the receipt at once and leaves the lookup, Stripe, the record and the emails to waitUntil', async () => {
    const res = await press({ email: 'a@example.com' }); // processDeclaration never settles here
    expect(res.status).toBe(200);
    expect(await res.text()).toContain('Your cancellation is received.');
    expect(work.processDeclaration).toHaveBeenCalledWith(expect.objectContaining({ email: 'a@example.com' }));
    expect(cf.waitUntil).toHaveBeenCalledWith(work.processDeclaration.mock.results[0].value);
  });

  // No cookie is involved, but another site could still make its visitors' browsers post cancellations, from as many
  // addresses as it has visitors, past the per-address limit.
  it('refuses a post from another site, or with no Origin, and does nothing with it', async () => {
    for (const headers of [{ origin: 'https://evil.example' }, { origin: 'null' }, {} as Record<string, string>]) {
      const res = await press({ email: 'a@example.com' }, headers);
      expect(res.status).toBe(403);
      expect(await res.text()).toContain('This cancellation was not received');
    }
    expect(cf.limit).not.toHaveBeenCalled();
    expect(work.processDeclaration).not.toHaveBeenCalled();
  });

  it('limits each IP address and each email, and receives nothing over the limit', async () => {
    await press({ email: 'A@Example.com' });
    expect(cf.limit.mock.calls.map(([o]) => o.key)).toEqual(['ip:203.0.113.9', 'email:a@example.com']);
    cf.limit.mockImplementation(async ({ key }) => ({ success: !key.startsWith('email:') }));
    const res = await press({ email: 'a@example.com' });
    expect(res.status).toBe(429);
    expect(await res.text()).toContain('this one was not received');
    expect(work.processDeclaration).toHaveBeenCalledTimes(1);
  });

  it('needs the email', async () => {
    expect((await press({})).status).toBe(400);
    expect(work.processDeclaration).not.toHaveBeenCalled();
  });
});
