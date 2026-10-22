import { describe, expect, it, vi } from 'vitest';
import { applySubscription, upsertUser } from './account';
import { cancelContract, confirmationText, declarationOf, receiptHtml, recordCancellation, type Declaration } from './cancel';
import { db } from './db';
import { useTestDb } from './test-db';

vi.mock('./db', () => import('./test-db'));
const stripe = vi.hoisted(() => ({ setCancelAtPeriodEnd: vi.fn(async () => true), cancelAt: vi.fn(async () => true) }));
vi.mock('./stripe', () => stripe);
useTestDb();

const at = new Date('2026-10-22T14:03:05.123Z');
const form = (o: Record<string, string>) => {
  const f = new FormData();
  for (const [k, v] of Object.entries(o)) f.set(k, v);
  return f;
};
const decl = (over: Partial<Declaration> = {}): Declaration => ({
  kind: 'ordinary',
  reason: '',
  contract: 'monthly',
  end: null,
  email: 'a@example.com',
  at,
  ...over,
});

// § 312k(4) BGB: the confirmation must carry what was declared, when it came in, and when the contract is to end.
describe('the confirmation', () => {
  it('names the declaration, the date and time it came in, and the end of the contract', () => {
    const t = confirmationText(decl({ kind: 'extraordinary', reason: 'Moved abroad', end: '2026-12-31' }));
    for (const s of ['Extraordinary cancellation for good cause', 'Reason: Moved abroad', 'shepetal monthly subscription', 'a@example.com', '2026-10-22 at 14:03:05 UTC', 'End of the contract: on 2026-12-31', 'Jetzt kündigen'])
      expect(t).toContain(s);
    expect(confirmationText(decl())).toContain('End of the contract: As soon as possible, at the end of the month already paid');
  });

  it('is a page that shows when it was sent and offers it as a file to keep, with the input escaped', () => {
    const html = receiptHtml(decl({ kind: 'extraordinary', reason: '<script>x</script>' }));
    expect(html).toContain('Sent with the Jetzt kündigen button on 2026-10-22 at 14:03:05 UTC.');
    expect(html).toMatch(/<a href="data:text\/plain;charset=utf-8,[^"]+" download="shepetal-cancellation-2026-10-22\.txt">/);
    expect(html).not.toContain('<script>');
  });
});

describe('the form', () => {
  it('needs only the email; everything else has a default, and a date counts only with "On this date"', () => {
    expect(declarationOf(form({}), at)).toBeNull();
    expect(declarationOf(form({ email: 'not an email' }), at)).toBeNull();
    expect(declarationOf(form({ email: ' A@Example.com ' }), at)).toEqual(decl({ email: 'A@Example.com' }));
    expect(declarationOf(form({ email: 'a@example.com', end: 'asap', date: '2026-12-31' }), at)?.end).toBeNull();
    expect(declarationOf(form({ email: 'a@example.com', end: 'date', date: '' }), at)?.end).toBeNull();
    expect(declarationOf(form({ email: 'a@example.com', end: 'date', date: '2026-12-31', kind: 'extraordinary', contract: 'lifetime' }), at))
      .toMatchObject({ end: '2026-12-31', kind: 'extraordinary', contract: 'lifetime' });
  });
});

describe('acting on it, with no sign-in', () => {
  const subscribe = async (email: string) => {
    const u = await upsertUser(email);
    const now = Math.floor(Date.now() / 1000);
    await applySubscription(u.id, { id: 'sub_1', status: 'active', current_period_start: now, current_period_end: now + 30 * 86_400, cancel_at_period_end: false, ended_at: null });
    return u;
  };

  it('stops a renewing subscription at the end of the paid month, matching the email in any case', async () => {
    const u = await subscribe('a@example.com');
    expect(await cancelContract(decl({ email: 'A@example.com' }))).toEqual({ userId: u.id, outcome: 'cancelled_at_period_end' });
    expect(stripe.setCancelAtPeriodEnd).toHaveBeenCalledWith(expect.objectContaining({ id: u.id }), true);
  });

  it('ends it on a requested date after the paid month, and never earlier than the paid month', async () => {
    await subscribe('a@example.com');
    expect((await cancelContract(decl({ end: '2099-01-31' }))).outcome).toBe('cancel_at');
    expect(stripe.cancelAt).toHaveBeenCalledWith(expect.anything(), Date.parse('2099-01-31T23:59:59Z') / 1000);
    expect((await cancelContract(decl({ end: '2020-01-01' }))).outcome).toBe('cancelled_at_period_end');
  });

  it('never creates an account (that would start a trial) and touches nothing for a lifetime license', async () => {
    stripe.setCancelAtPeriodEnd.mockClear();
    expect(await cancelContract(decl({ email: 'nobody@example.com' }))).toEqual({ userId: null, outcome: 'no_account' });
    expect((await db().prepare('SELECT COUNT(*) AS n FROM users').first<{ n: number }>())?.n).toBe(0);
    await subscribe('a@example.com');
    expect((await cancelContract(decl({ contract: 'lifetime' }))).outcome).toBe('no_subscription');
    expect(stripe.setCancelAtPeriodEnd).not.toHaveBeenCalled();
  });

  it('records every declaration, and deletes those three years past the end of their year', async () => {
    await recordCancellation(decl({ at: new Date('2022-12-31T23:00:00Z') }), null, 'no_account');
    await recordCancellation(decl({ at: new Date('2023-01-01T00:00:00Z') }), null, 'no_account');
    await recordCancellation(decl({ kind: 'extraordinary', reason: 'r', end: '2026-12-31' }), 7, 'cancel_at');
    const rows = (await db().prepare('SELECT received_at, kind, reason, end_requested, user_id, outcome FROM cancellations ORDER BY id').all()).results;
    expect(rows).toEqual([
      { received_at: '2023-01-01T00:00:00.000Z', kind: 'ordinary', reason: null, end_requested: null, user_id: null, outcome: 'no_account' },
      { received_at: at.toISOString(), kind: 'extraordinary', reason: 'r', end_requested: '2026-12-31', user_id: 7, outcome: 'cancel_at' },
    ]);
  });
});
