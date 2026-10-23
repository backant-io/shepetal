import { beforeEach, describe, expect, it, vi } from 'vitest';
import { analyticsConfig, attribution, attributionQuery, capture, userId, visitorId } from './analytics';
import { db, useTestDb } from './test-db';
import { forgetDailyKey } from './visitor-salt';

vi.mock('./db', () => import('./test-db'));
useTestDb();

const req = (ip: string, ua: string, path = '/download') => new Request(`https://shepetal.app${path}`, { headers: { 'cf-connecting-ip': ip, 'user-agent': ua } });
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
  const day = Date.parse('2026-10-22T08:00:00Z');
  const D = 86_400_000;
  beforeEach(() => forgetDailyKey());
  const salts = async () => (await db().prepare('SELECT day FROM visitor_salts ORDER BY day').all<{ day: string }>()).results.map((r) => r.day);

  it('a visitor is the same all day on every route (page, download, app sign-in), so they join; and never contains the IP or the user agent', async () => {
    const a = await visitorId(req('203.0.113.7', 'Mozilla/5.0'), day, db());
    expect(await visitorId(req('203.0.113.7', 'Mozilla/5.0', '/'), day + 3_600_000, db())).toBe(a);
    expect(await visitorId(req('203.0.113.7', 'Mozilla/5.0', '/app/login'), day + 15 * 3_600_000, db())).toBe(a);
    expect(await visitorId(req('203.0.113.8', 'Mozilla/5.0'), day, db())).not.toBe(a);
    expect(a).toMatch(/^v_[0-9a-f]{32}$/);
    expect(a).not.toContain('203');
  });

  it('the salt is random per UTC day: the same visitor is a new id tomorrow, and a salt is gone after 48 h', async () => {
    const r = () => req('203.0.113.7', 'Mozilla/5.0');
    const today = await visitorId(r(), day, db());
    const tomorrow = await visitorId(r(), day + D, db());
    expect(tomorrow).not.toBe(today);
    expect(await salts()).toEqual(['2026-10-22', '2026-10-23']);
    // On the 24th the 22nd's salt is deleted: nothing can recompute an id from that day any more.
    await visitorId(r(), day + 2 * D, db());
    expect(await salts()).toEqual(['2026-10-23', '2026-10-24']);
  });

  it('the salt is not derived from anything we keep: a new salt for the same day gives the same visitor another id', async () => {
    const a = await visitorId(req('203.0.113.7', 'Mozilla/5.0'), day, db());
    await db().prepare('DELETE FROM visitor_salts').run();
    forgetDailyKey();
    expect(await visitorId(req('203.0.113.7', 'Mozilla/5.0'), day, db())).not.toBe(a);
  });

  it('an isolate reads D1 once a day (CPU and D1 reads on the Free plan), and every isolate agrees on the day’s salt', async () => {
    let reads = 0;
    const counted = new Proxy(db(), { get: (t, k) => (k === 'batch' ? (...a: Parameters<D1Database['batch']>) => (reads++, t.batch(...a)) : Reflect.get(t, k).bind?.(t) ?? Reflect.get(t, k)) });
    const first = await Promise.all([1, 2, 3].map((i) => visitorId(req('203.0.113.7', 'Mozilla/5.0'), day + i, counted)));
    for (let i = 0; i < 20; i++) await visitorId(req(`203.0.113.${i}`, 'Mozilla/5.0'), day + i * 1000, counted);
    expect(reads).toBe(1);
    // Another isolate (no key in memory) reads the row the first one wrote, so the id is the same.
    forgetDailyKey();
    expect(await visitorId(req('203.0.113.7', 'Mozilla/5.0'), day + 5, counted)).toBe(first[0]);
    expect(new Set(first).size).toBe(1);
    await visitorId(req('203.0.113.7', 'Mozilla/5.0'), day + D, counted);
    expect(reads).toBe(3);
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
