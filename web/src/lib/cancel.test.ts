import { beforeEach, describe, expect, it, vi } from 'vitest';
import { activate, applySubscription, upsertUser } from './account';
import {
  cancelContract,
  declarationOf,
  declarationText,
  ipKey,
  plain,
  processDeclaration,
  receiptHtml,
  recordCancellation,
  confirmationText,
  type Declaration,
  type Handling,
} from './cancel';
import { db } from './db';
import { useTestDb } from './test-db';

vi.mock('./db', () => import('./test-db'));
const stripe = vi.hoisted(() => ({ cancelAt: vi.fn() }));
vi.mock('./stripe', () => stripe);
const mail = vi.hoisted(() => ({ OWNER: 'owner@example.com', sendMail: vi.fn(async () => {}), sesEnabled: vi.fn(() => false) }));
vi.mock('./mail', () => mail);
useTestDb();

const at = new Date('2026-10-22T14:03:05.123Z');
const ENDS = '2026-11-21T14:00:00.000Z';
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
  now: false,
  badDate: null,
  email: 'a@example.com',
  at,
  ...over,
});
const subscribe = async (email: string) => {
  const u = await upsertUser(email);
  const now = Math.floor(Date.now() / 1000);
  await applySubscription(u.id, { id: 'sub_1', status: 'active', current_period_start: now, current_period_end: now + 30 * 86_400, cancel_at_period_end: false, ended_at: null });
  return u;
};
beforeEach(() => {
  vi.clearAllMocks();
  stripe.cancelAt.mockResolvedValue({ ends_at: ENDS, changed: true });
  mail.sesEnabled.mockReturnValue(false);
});

// § 312k(3) BGB: the consumer keeps what was declared and when; § 312k(5): a missing or unusable date means as soon as
// possible, and the text says so instead of echoing a date that will not happen.
describe('the declaration', () => {
  it('names the declaration, the date and time it came in, and the end asked for', () => {
    const t = declarationText(decl({ kind: 'extraordinary', reason: 'Moved abroad', end: '2026-12-31' }));
    for (const s of ['Extraordinary cancellation for good cause', 'Reason: Moved abroad', 'shepetal monthly subscription', 'a@example.com', '2026-10-22 at 14:03:05 UTC', 'End of the contract: 2026-12-31, not before the end of the period already paid, and at most three months after it', 'Jetzt kündigen'])
      expect(t).toContain(s);
    expect(declarationText(decl())).toContain('End of the contract: As soon as possible, at the end of the period already paid\n');
  });

  it('needs only the email; a date counts if it is a real later day, even without "On this date"', () => {
    expect(declarationOf(form({}), at)).toBeNull();
    expect(declarationOf(form({ email: 'not an email' }), at)).toBeNull();
    expect(declarationOf(form({ email: ' A@Example.com ' }), at)).toEqual(decl({ email: 'A@Example.com' }));
    expect(declarationOf(form({ email: 'a@example.com', end: 'date', date: '' }), at)?.end).toBeNull();
    expect(declarationOf(form({ email: 'a@example.com', date: '2026-12-31' }), at)?.end).toBe('2026-12-31');
    expect(declarationOf(form({ email: 'a@example.com', end: 'date', date: '2026-12-31', kind: 'extraordinary', contract: 'lifetime' }), at))
      .toMatchObject({ end: '2026-12-31', kind: 'extraordinary', contract: 'lifetime' });
  });

  // § 312k(5): what the consumer chose decides. A date typed and then left behind when they picked "as soon as
  // possible" must not keep the contract (and its charges) running until that date.
  it('lets an explicitly chosen "as soon as possible" or "right away" win over a date left in the field', () => {
    expect(declarationOf(form({ email: 'a@example.com', end: 'asap', date: '2026-12-31' }), at)).toMatchObject({ end: null, now: false, badDate: null });
    expect(declarationOf(form({ email: 'a@example.com', end: 'asap', date: 'garbage' }), at)).toMatchObject({ end: null, badDate: null });
    const now = declarationOf(form({ email: 'a@example.com', kind: 'extraordinary', end: 'now', date: '2026-12-31' }), at)!;
    expect(now).toMatchObject({ end: null, now: true, badDate: null });
    expect(declarationText(now)).toContain('End of the contract: Right away, for an extraordinary cancellation\n');
    // An ordinary cancellation cannot end before the paid period does: it says so instead of promising "right away".
    expect(declarationText(decl({ now: true }))).toContain('End of the contract: As soon as possible, at the end of the period already paid (right away is for an extraordinary cancellation)');
  });

  it('treats a past, same-day or impossible date as as soon as possible, and says so', () => {
    for (const date of ['2020-01-01', '2026-10-22', '2027-02-31', '2027-13-01', 'tomorrow']) {
      const d = declarationOf(form({ email: 'a@example.com', end: 'date', date }), at)!;
      expect(d, date).toMatchObject({ end: null, badDate: date });
      expect(declarationText(d)).toContain(`End of the contract: As soon as possible, at the end of the period already paid (the date entered, ${date}, is not a day after today)`);
    }
  });
});

// The receipt goes back before anything is done (POST /api/cancel), so it can never say a subscription stopped:
// that is only true once Stripe has it, and a failure there must not leave a customer believing it.
describe('the receipt', () => {
  it('shows when it was sent, offers it as a file, escapes the input, and never claims a result', () => {
    const html = receiptHtml(decl({ kind: 'extraordinary', reason: '<script>x</script>' }), false);
    expect(html).toContain('Sent with the Jetzt kündigen button on 2026-10-22 at 14:03:05 UTC.');
    expect(html).toMatch(/<a href="data:text\/plain;charset=utf-8,[^"]+" download="shepetal-cancellation-2026-10-22\.txt">/);
    expect(html).not.toContain('<script>');
    expect(html).toContain('It will be processed now.');
    expect(html).not.toMatch(/stops renewing|is cancelled|has been cancelled|was cancelled/i);
  });

  it('says honestly whether a confirmation email follows: never that one was sent while SES is off', () => {
    const off = receiptHtml(decl(), false);
    expect(off).toContain('no email has been sent');
    expect(off).not.toMatch(/goes to it by email|we have emailed|email was sent/i);
    expect(receiptHtml(decl(), true)).toContain('the confirmation, with the date your contract ends, goes to it by email');
  });

  it('is the same page for every email, so it tells no one which have an account', () => {
    const blank = (h: string, who: string) => h.replaceAll(who, '@').replaceAll(encodeURIComponent(who), '@');
    expect(blank(receiptHtml(decl({ email: 'x@example.com' }), false), 'x@example.com')).toBe(blank(receiptHtml(decl({ email: 'someone.else@example.org' }), false), 'someone.else@example.org'));
  });
});

// Anyone who knows an account's email can fill in the form, and the confirmation goes from support@shepetal.app to
// that account. Whatever they typed and the email carries back is a phishing message signed by us.
describe('what goes back to the customer', () => {
  it('never carries the reason as typed: the account email says "as entered on the form"', () => {
    const lure = 'Your card was declined. Log in at https://shepetal-billing.example/login to keep shepetal';
    const d = decl({ kind: 'extraordinary', reason: lure });
    const text = confirmationText(d, { user: null, outcome: 'cancelled', endsAt: ENDS, error: null });
    expect(text).toContain('Reason: as entered on the form');
    expect(text).not.toContain('declined');
    expect(text).not.toContain('shepetal-billing');
    // The sender's own receipt and Pavel's copy keep it.
    expect(declarationText(d)).toContain(`Reason: ${lure}`);
  });

  it('caps what else it echoes and takes links out of it', () => {
    expect(plain('bit.ly/abc')).toBe('[link removed]');
    expect(plain('https://x.example/a b', 100)).toBe('[link removed] b');
    expect(plain('2027-13-01')).toBe('2027-13-01');
    expect(plain('x'.repeat(100))).toHaveLength(40);
    const text = confirmationText(decl({ badDate: 'evil.co/xx' }), { user: null, outcome: 'cancelled', endsAt: ENDS, error: null });
    expect(text).toContain('(the date entered, [link removed], is not a day after today)');
    expect(text).not.toContain('evil.co');
  });

  it('with SES on, sends the account no reason, even for an extraordinary cancellation', async () => {
    mail.sesEnabled.mockReturnValue(true);
    await subscribe('a@example.com');
    await processDeclaration(decl({ kind: 'extraordinary', reason: 'Visit https://phish.example now' }));
    const calls = mail.sendMail.mock.calls as unknown as [string, string, string][];
    const [[, , toCustomer]] = calls.filter(([to]) => to !== mail.OWNER);
    expect(toCustomer).not.toMatch(/phish|Visit/);
    const [[, , notice]] = calls.filter(([to]) => to === mail.OWNER);
    expect(notice).toContain('Reason: Visit https://phish.example now');
  });
});

// One host holds a whole IPv6 /64 and can send from any address in it: a key per address would let it flood Pavel's
// mailbox and D1 at 5 a minute per address.
describe('the throttle key', () => {
  it('keys IPv4 by the full address and IPv6 by its /64 prefix, however it is written', () => {
    expect(ipKey('203.0.113.9')).toBe('203.0.113.9');
    expect(ipKey('::ffff:203.0.113.9')).toBe('203.0.113.9');
    const prefix = '2001:db8:85a3:1::/64';
    for (const ip of ['2001:db8:85a3:1::1', '2001:0db8:85a3:0001:ffff:ffff:ffff:ffff', '2001:DB8:85A3:1:1234:5678:9abc:def0', '2001:db8:85a3:1::7%eth0'])
      expect(ipKey(ip), ip).toBe(prefix);
    expect(ipKey('2001:db8:85a3:2::1')).not.toBe(prefix);
    expect(ipKey('2001:db8::1')).toBe('2001:db8:0:0::/64');
    expect(ipKey('::1')).toBe('0:0:0:0::/64');
  });
});

describe('acting on it, with no sign-in', () => {
  it('ends a subscription as soon as possible, matching the email in any case', async () => {
    const u = await subscribe('a@example.com');
    expect(await cancelContract(decl({ email: 'A@example.com' }))).toMatchObject({ user: { id: u.id }, outcome: 'cancelled', endsAt: ENDS, error: null });
    expect(stripe.cancelAt).toHaveBeenCalledWith(expect.objectContaining({ id: u.id }), null);
  });

  it('asks for the end of the requested day (stripe.ts caps it)', async () => {
    await subscribe('a@example.com');
    await cancelContract(decl({ end: '2027-01-31' }));
    expect(stripe.cancelAt).toHaveBeenCalledWith(expect.anything(), Date.parse('2027-01-31T23:59:59Z') / 1000);
  });

  it('still ends the subscription of a subscriber who picked "lifetime license" (an account has one or the other)', async () => {
    await subscribe('a@example.com');
    expect((await cancelContract(decl({ contract: 'lifetime' }))).outcome).toBe('cancelled');
    expect(stripe.cancelAt).toHaveBeenCalled();
  });

  it('never creates an account (that would start a trial), and leaves a lifetime license as it is', async () => {
    expect(await cancelContract(decl({ email: 'nobody@example.com' }))).toEqual({ user: null, outcome: 'no_account', endsAt: null, error: null });
    expect((await db().prepare('SELECT COUNT(*) AS n FROM users').first<{ n: number }>())?.n).toBe(0);
    const u = await upsertUser('l@example.com');
    await activate(u.id, 'pi_1');
    stripe.cancelAt.mockResolvedValue(null);
    expect((await cancelContract(decl({ email: 'l@example.com', contract: 'lifetime' }))).outcome).toBe('lifetime');
  });

  it('turns a Stripe failure into outcome "error" with the message, never a throw', async () => {
    await subscribe('a@example.com');
    stripe.cancelAt.mockRejectedValue(new Error('Stripe is down'));
    expect(await cancelContract(decl())).toMatchObject({ outcome: 'error', endsAt: null, error: 'Stripe is down' });
  });

  it('records every declaration with what was done, and deletes those three years past the end of their year', async () => {
    const h = (over: Partial<Handling> = {}): Handling => ({ user: null, outcome: 'no_account', endsAt: null, error: null, ...over });
    await recordCancellation(decl({ at: new Date('2022-12-31T23:00:00Z') }), h());
    await recordCancellation(decl({ at: new Date('2023-01-01T00:00:00Z') }), h());
    await recordCancellation(decl({ kind: 'extraordinary', reason: 'r', end: '2026-12-31' }), h({ user: { id: 7 } as never, outcome: 'cancelled', endsAt: ENDS }));
    await recordCancellation(decl({ kind: 'extraordinary', reason: 'r', now: true }), h({ user: { id: 7 } as never, outcome: 'cancelled', endsAt: ENDS }));
    const rows = (await db().prepare('SELECT received_at, kind, reason, end_requested, user_id, outcome, ends_at FROM cancellations ORDER BY id').all()).results;
    expect(rows).toEqual([
      { received_at: '2023-01-01T00:00:00.000Z', kind: 'ordinary', reason: null, end_requested: null, user_id: null, outcome: 'no_account', ends_at: null },
      { received_at: at.toISOString(), kind: 'extraordinary', reason: 'r', end_requested: '2026-12-31', user_id: 7, outcome: 'cancelled', ends_at: ENDS },
      { received_at: at.toISOString(), kind: 'extraordinary', reason: 'r', end_requested: 'now', user_id: 7, outcome: 'cancelled', ends_at: ENDS },
    ]);
  });
});

// Anyone who knows a subscriber's email can press the button. The owner must learn of it (the § 312k(4) email to the
// account, once SES is set up) and Pavel must see every declaration, especially the ones a person has to act on.
describe('after the answer: the record, the confirmation and the notice', () => {
  const notice = () => {
    const calls = mail.sendMail.mock.calls as unknown as [string, string, string][];
    const n = calls.filter(([to]) => to === mail.OWNER);
    expect(n).toHaveLength(1);
    return { subject: n[0][1], text: n[0][2] };
  };
  const toCustomer = () => (mail.sendMail.mock.calls as unknown as [string, string, string][]).filter(([to]) => to !== mail.OWNER);

  // The receipt and its download stay the same for every email (no enumeration), so only Pavel's notice can say that
  // nothing was found: if the person writes, he answers by hand.
  it('tells Pavel of every declaration, marking one for an unknown email UNMATCHED, and emails no stranger', async () => {
    await processDeclaration(decl({ email: 'nobody@example.com' }));
    expect(notice().subject).toBe('cancel: no_account (UNMATCHED): nobody@example.com');
    expect(notice().text).toContain('Account: UNMATCHED, none under this email');
    expect(notice().text).toContain('TO DO: UNMATCHED: no account has this email');
    expect(toCustomer()).toEqual([]);
    expect((await db().prepare('SELECT outcome FROM cancellations').all()).results).toEqual([{ outcome: 'no_account' }]);
  });

  it('with SES on, confirms to the address of the account (not the spelling typed), with the end and the undo link', async () => {
    mail.sesEnabled.mockReturnValue(true);
    await subscribe('a@example.com');
    await processDeclaration(decl({ email: 'A@EXAMPLE.com' }));
    const [[to, subject, text]] = toCustomer();
    expect([to, subject]).toEqual(['a@example.com', 'Your cancellation of shepetal (Kündigungsbestätigung)']);
    for (const s of ['Received by BackAnt, Inc. on 2026-10-22 at 14:03:05 UTC.', 'It ends on 2026-11-21 at 14:00:00 UTC', '/account and choose Resume subscription'])
      expect(text).toContain(s);
    expect(notice().text).toContain('Confirmation to the customer: sent to a@example.com');
  });

  it('with SES off, sends the customer nothing and gives Pavel the text to send by hand', async () => {
    await subscribe('a@example.com');
    await processDeclaration(decl());
    expect(toCustomer()).toEqual([]);
    expect(notice().text).toContain('not sent: SES is not set up. Send the text below to a@example.com by hand.');
    expect(notice().text).toContain('--- The confirmation ---');
  });

  it('when Stripe fails, the confirmation claims no end and Pavel gets the error to act on', async () => {
    mail.sesEnabled.mockReturnValue(true);
    await subscribe('a@example.com');
    stripe.cancelAt.mockRejectedValue(new Error('Stripe is down'));
    await processDeclaration(decl());
    const [[, , text]] = toCustomer();
    expect(text).toContain('Your cancellation is received and will be processed.');
    expect(text).not.toMatch(/is cancelled|stops renewing|ends on/);
    expect(notice().subject).toBe('cancel: error (PROBLEM): a@example.com');
    expect(notice().text).toContain('PROBLEM: acting on it failed: Stripe is down');
    expect(notice().text).toContain('TO DO: Cancel it by hand in Stripe');
  });

  it('flags an extraordinary cancellation, and a lifetime license, for a decision', async () => {
    await subscribe('a@example.com');
    await processDeclaration(decl({ kind: 'extraordinary', reason: 'Moved abroad' }));
    expect(notice().subject).toBe('cancel: cancelled (extraordinary): a@example.com');
    expect(notice().text).toContain('Reason: Moved abroad');
    expect(notice().text).toContain('TO DO: Extraordinary: decide whether it ends at once');
    expect(confirmationText(decl({ kind: 'extraordinary' }), { user: null, outcome: 'cancelled', endsAt: ENDS, error: null })).toContain('You cancelled for good cause');
    vi.clearAllMocks();
    const u = await upsertUser('l@example.com');
    await activate(u.id, 'pi_1');
    stripe.cancelAt.mockResolvedValue(null);
    await processDeclaration(decl({ email: 'l@example.com', contract: 'lifetime' }));
    expect(notice().text).toContain('TO DO: Lifetime license');
  });

  // § 312k(5) and (4): "right away" for good cause is Pavel's decision, so the confirmation must not name an end as if
  // it were decided. It may say the latest end, which Stripe has.
  it('confirms an extraordinary "right away" without a false end: decided by hand, and written to them', () => {
    const text = confirmationText(decl({ kind: 'extraordinary', now: true }), { user: null, outcome: 'cancelled', endsAt: ENDS, error: null });
    expect(text).toContain('it ends on 2026-11-21 at 14:00:00 UTC at the latest');
    expect(text).toContain('decide when it ends and what is refunded, and write to you');
    expect(text).not.toContain('Your subscription is cancelled. It ends on');
  });

  // A date after the paid month: Stripe renews once more and bills the shortened last period. "Nothing is charged after
  // that" alone would hide that charge.
  it('says when one more, shortened charge comes before a later end date', () => {
    const user = { id: 1, email: 'a@example.com', paid_through: '2026-11-21T14:00:00.000Z' } as never;
    const later = confirmationText(decl({ end: '2026-12-31' }), { user, outcome: 'cancelled', endsAt: '2026-12-31T23:59:59.000Z', error: null });
    expect(later).toContain('On 2026-11-21 at 14:00:00 UTC it is charged once more, only for the days up to that end. Nothing is charged after that.');
    expect(confirmationText(decl(), { user, outcome: 'cancelled', endsAt: '2026-11-21T14:00:00.000Z', error: null })).toContain('and nothing is charged after that.');
  });

  it('still notifies Pavel when the record cannot be written', async () => {
    await db().prepare('ALTER TABLE cancellations RENAME TO c_gone').run();
    try {
      await processDeclaration(decl({ email: 'nobody@example.com' }));
      expect(notice().text).toMatch(/PROBLEM: recording it in D1 failed/);
    } finally {
      await db().prepare('ALTER TABLE c_gone RENAME TO cancellations').run();
    }
  });
});
