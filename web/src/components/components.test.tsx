import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it, vi } from 'vitest';
import { startCheckout } from './BuyButton';
import { daysLeft, LicenseSummary } from './LicenseSummary';

const json = (status: number, body: unknown) =>
  vi.fn<typeof fetch>(async () => new Response(JSON.stringify(body), { status }));

describe('Buy button', () => {
  it('posts to /api/checkout and opens the Stripe url it returns', async () => {
    const f = json(200, { url: 'https://checkout.stripe.com/c/pay/cs_test_1' });
    expect(await startCheckout(f)).toEqual({ url: 'https://checkout.stripe.com/c/pay/cs_test_1' });
    expect(f).toHaveBeenCalledWith('/api/checkout', { method: 'POST' });
  });

  it('tells a signed-out user to sign in again, and an owner that they already own it, so nobody pays twice', async () => {
    expect(await startCheckout(json(401, { error: 'unauthorized' }))).toEqual({ error: expect.stringMatching(/sign in again/) });
    expect(await startCheckout(json(409, { error: 'already_active' }))).toEqual({ error: expect.stringMatching(/already own/) });
  });

  it('never navigates on a server error, a missing url or a network failure', async () => {
    for (const f of [json(500, { url: 'https://checkout.stripe.com/x' }), json(200, {}), vi.fn<typeof fetch>(async () => Promise.reject(new Error('offline')))]) {
      expect(await startCheckout(f)).toEqual({ error: expect.stringMatching(/did not open/) });
    }
  });
});

describe('/account license summary', () => {
  const DAY = 86_400_000;
  const now = Date.parse('2026-10-20T12:00:00.000Z');
  const email = 'a@example.com';

  it('counts trial days up, so a fresh trial shows 30 and the last hours still show 1', () => {
    expect(daysLeft(new Date(now + 30 * DAY).toISOString(), now)).toBe(30);
    expect(daysLeft(new Date(now + 2 * 3_600_000).toISOString(), now)).toBe(1);
    expect(daysLeft(new Date(now - DAY).toISOString(), now)).toBe(0);
  });

  it('shows days left during the trial', () => {
    const html = renderToStaticMarkup(
      <LicenseSummary license={{ status: 'trial', trial_ends_at: new Date(now + 12.5 * DAY).toISOString(), email }} now={now} />,
    );
    expect(html).toContain('13 days left');
    expect(html).toContain('November 2, 2026');
  });

  it('shows "yours forever" for a purchase, with no trial date', () => {
    const html = renderToStaticMarkup(<LicenseSummary license={{ status: 'active', trial_ends_at: null, email }} now={now} />);
    expect(html).toContain('Yours forever');
    expect(html).not.toContain('left');
  });

  it('asks for the one-time $4.99 once the trial ended', () => {
    const html = renderToStaticMarkup(
      <LicenseSummary license={{ status: 'expired', trial_ends_at: '2026-10-01T00:00:00.000Z', email }} now={now} />,
    );
    expect(html).toContain('Your trial ended');
    expect(html).toContain('$4.99');
  });
});
