import { describe, expect, it, vi } from 'vitest';
import { analyticsConfig, attribution, attributionQuery, capture, userId, visitorId } from './analytics';

const req = (ip: string, ua: string) => new Request('https://shepetal.app/download', { headers: { 'cf-connecting-ip': ip, 'user-agent': ua } });
const ok = () => vi.fn<typeof fetch>(async () => new Response('{}', { status: 200 }));

describe('analytics: off without a key', () => {
  it('sends nothing when POSTHOG_KEY is empty, and uses backant’s US host by default', async () => {
    const f = ok();
    expect(await capture('download_served', 'v_x', {}, { POSTHOG_KEY: '' }, f)).toBe(false);
    expect(f).not.toHaveBeenCalled();
    expect(analyticsConfig({})).toEqual({ key: '', host: 'https://us.i.posthog.com' });
  });
});

describe('analytics: what one event carries', () => {
  const env = { POSTHOG_KEY: 'phc_test', POSTHOG_HOST: 'https://us.i.posthog.com/' };

  it('posts to the capture API, tagged app=shepetal, with no person profile for a visitor', async () => {
    const f = ok();
    expect(await capture('download_served', 'v_abc', { version: '0.3.0', ref: 'producthunt' }, env, f)).toBe(true);
    const [url, init] = f.mock.calls[0];
    expect(url).toBe('https://us.i.posthog.com/i/v0/e/');
    const body = JSON.parse(String(init?.body));
    expect(body).toMatchObject({ api_key: 'phc_test', event: 'download_served', distinct_id: 'v_abc' });
    expect(body.properties).toMatchObject({ app: 'shepetal', version: '0.3.0', ref: 'producthunt', $process_person_profile: false, $geoip_disable: true });
  });

  it('tags a signed-in user’s person with app=shepetal', async () => {
    const f = ok();
    await capture('checkout_completed', 'u_abc', { plan: 'lifetime' }, env, f);
    expect(JSON.parse(String(f.mock.calls[0][1]?.body)).properties).toMatchObject({ app: 'shepetal', plan: 'lifetime', $set: { app: 'shepetal' } });
  });

  it('never throws when PostHog is down', async () => {
    expect(await capture('appcast_check', 'v_x', {}, env, vi.fn<typeof fetch>(async () => Promise.reject(new Error('down'))))).toBe(false);
  });
});

describe('analytics: ids are hashes', () => {
  it('a visitor is the same all day, new the next day, and never contains the IP or the user agent', async () => {
    const day = Date.parse('2026-10-22T08:00:00Z');
    const a = await visitorId(req('203.0.113.7', 'Mozilla/5.0'), day, 'salt');
    expect(await visitorId(req('203.0.113.7', 'Mozilla/5.0'), day + 3_600_000, 'salt')).toBe(a);
    expect(await visitorId(req('203.0.113.7', 'Mozilla/5.0'), day + 86_400_000, 'salt')).not.toBe(a);
    expect(await visitorId(req('203.0.113.8', 'Mozilla/5.0'), day, 'salt')).not.toBe(a);
    expect(a).toMatch(/^v_[0-9a-f]{32}$/);
    expect(a).not.toContain('203');
  });

  it('a user is a salted hash of the email, whatever its case', async () => {
    const u = await userId('Ana@Example.com', 'salt');
    expect(u).toBe(await userId('ana@example.com', 'salt'));
    expect(u).toMatch(/^u_[0-9a-f]{32}$/);
    expect(await userId('ana@example.com', 'other')).not.toBe(u);
  });
});

describe('analytics: where a visitor came from', () => {
  it('keeps ref and the utm fields, clean and short, and carries them on as a query', () => {
    const a = attribution(new URLSearchParams('ref=producthunt&utm_source=x.com&utm_campaign=launch-1&utm_medium=<script>&other=1'));
    expect(a).toEqual({ ref: 'producthunt', utm_source: 'x.com', utm_campaign: 'launch-1' });
    expect(attributionQuery(a)).toBe('?ref=producthunt&utm_source=x.com&utm_campaign=launch-1');
    expect(attributionQuery({})).toBe('');
    expect(attribution(new URLSearchParams(`ref=${'a'.repeat(65)}`))).toEqual({});
  });
});
