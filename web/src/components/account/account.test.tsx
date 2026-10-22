import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { licenseOf, planSettings, type User } from '@/lib/account';
import { AccountBody, notice, scrollToHash } from './Account';

// /account is static and filled in by the browser from GET /api/account ({license, settings}): the copy a signed-in
// user reads per plan, which the e2e used to read from server-rendered HTML.

const NOW = Date.parse('2026-10-22T12:00:00.000Z');
const DAY = 86_400_000;
const iso = (ms: number) => new Date(ms).toISOString();
const base: User = { id: 1, email: 'a@example.com', trial_started_at: iso(NOW), status: 'trial', purchased_at: null };
const subscriber: User = {
  ...base,
  plan: 'subscription',
  stripe_customer_id: 'cus_1',
  sub_id: 'sub_1',
  sub_status: 'active',
  current_period_end: iso(NOW + 30 * DAY),
  paid_through: iso(NOW + 30 * DAY),
  cancel_at_period_end: 0,
  sub_amount: 99,
  sub_currency: 'usd',
};
const lifetime: User = { ...base, status: 'active', plan: 'lifetime', purchased_at: iso(NOW), stripe_customer_id: 'cus_1' };

/** The page as text, the way a reader sees it. */
const text = (u: User, search = '') =>
  renderToStaticMarkup(<AccountBody license={licenseOf(u, NOW)} settings={planSettings(u, NOW)} search={search} now={NOW} />)
    .replace(/<[^>]+>/g, ' ')
    .replace(/\s+/g, ' ');

describe('the account page, per plan', () => {
  it('trial: days left, the download, the email and the two plans; no subscription controls', () => {
    const t = text(base);
    for (const s of ['30 days left.', 'Download for Mac', 'Settings', 'a@example.com', 'Free trial', '$23.99', 'once. Yours forever.', '$0.99', 'a month.', 'Buy once', 'Subscribe'])
      expect(t, s).toContain(s);
    for (const s of ['Cancel subscription', 'Switch to lifetime', 'Manage billing']) expect(t, s).not.toContain(s);
  });

  it('subscriber: status, next charge, Manage billing, Switch to lifetime, Cancel subscription with a confirmation', () => {
    const t = text(subscriber);
    for (const s of ['$0.99 a month.', 'Monthly', 'Active', 'Next charge', 'Manage billing', 'Switch to lifetime', 'Cancel subscription', 'Cancel your subscription?', 'nothing is charged again'])
      expect(t, s).toContain(s);
    expect(t).not.toContain('Buy once');
  });

  it('lifetime: "Yours forever." and no subscription controls', () => {
    const t = text(lifetime);
    for (const s of ['Yours forever.', 'Lifetime', 'Download for Mac']) expect(t, s).toContain(s);
    for (const s of ['Cancel subscription', 'Switch to lifetime', 'Manage billing', 'Next charge', 'Buy once']) expect(t, s).not.toContain(s);
  });

  it('says what happened after a round trip to Stripe', () => {
    const q = (s: string) => new URLSearchParams(s);
    expect(notice(q('purchased=1'), false, false)).toMatch(/can take a minute/);
    expect(notice(q('purchased=1'), true, true)).toBe('Yours forever, updates included. Thank you.');
    expect(notice(q('purchased=1'), true, false)).toBe('Your subscription is on. Thank you.');
    expect(notice(q('cancelled=1'), true, false)).toMatch(/cancelled/);
    expect(notice(q('portal=none'), false, false)).toBe('Billing opens once you have bought a plan.');
    expect(notice(q(''), true, false)).toBeNull();
    expect(text(lifetime, '?purchased=1')).toContain('Yours forever, updates included. Thank you.');
  });

  it('carries ?ref= and utm_* (nothing else) on to /install, where the download counts them', () => {
    const html = renderToStaticMarkup(<AccountBody license={licenseOf(base, NOW)} settings={planSettings(base, NOW)} search="?ref=hn&utm_source=x&purchased=1&next=//evil" now={NOW} />);
    expect(html).toContain('href="/install?ref=hn&amp;utm_source=x"');
    expect(renderToStaticMarkup(<AccountBody license={licenseOf(base, NOW)} settings={planSettings(base, NOW)} search="" now={NOW} />)).toContain('href="/install"');
  });

  it('is static: no session, no database and no server action in the page (worker.ts redirects signed-out visits)', () => {
    const page = readFileSync(join(__dirname, '..', '..', 'app', '(site)', 'account', 'page.tsx'), 'utf8');
    expect(page).not.toMatch(/@\/lib\/auth|upsertUser|use server|searchParams/);
    expect(page).toContain('action="/api/auth/signout"');
  });
});

// The Mac app's Buy button opens /account#plans. The account renders in the browser after GET /api/account, so the
// browser's own jump to #plans on load finds nothing: the page scrolls there itself once the plans are in.
describe('/account#plans, the apps’ Buy link', () => {
  const html = (u: User) => renderToStaticMarkup(<AccountBody license={licenseOf(u, NOW)} settings={planSettings(u, NOW)} search="" now={NOW} />);

  it('renders id="plans" for everyone who can buy: a trial, an ended trial, an ended subscription', () => {
    const ended: User = { ...subscriber, plan: null, sub_status: 'canceled', current_period_end: iso(NOW - DAY), paid_through: iso(NOW - DAY) };
    for (const u of [base, { ...base, trial_started_at: iso(NOW - 40 * DAY) }, ended]) expect(html(u).match(/id="plans"/g), JSON.stringify(u)).toHaveLength(1);
    expect(html(lifetime)).not.toContain('id="plans"'); // nothing left to buy
  });

  it('scrolls to the element the fragment names once it is there, and to nothing otherwise', () => {
    const scrolled: string[] = [];
    const doc = { getElementById: (id: string) => (id === 'plans' ? ({ scrollIntoView: () => scrolled.push(id) } as unknown as HTMLElement) : null) };
    expect(scrollToHash('#plans', doc)).toBe(true);
    expect(scrolled).toEqual(['plans']);
    for (const hash of ['', '#', '#nope', '#%E0%A4%A']) expect(scrollToHash(hash, doc), hash).toBe(false);
    expect(scrolled).toEqual(['plans']);
  });

  it('is wired: Account scrolls after the account data has rendered', () => {
    const src = readFileSync(join(__dirname, 'Account.tsx'), 'utf8');
    expect(src).toMatch(/useEffect\(\(\) => \{\s*if \(data\) scrollToHash\(location\.hash, document\);\s*\}, \[data\]\);/);
  });
});
