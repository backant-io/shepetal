import { beforeEach, describe, expect, it, vi } from 'vitest';
import { activate, applySubscription, upsertUser } from './account';
import {
  cancelContract,
  declarationOf,
  declarationText,
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
    expect(declarationOf(form({ email: 'a@example.com', end: 'asap', date: '2026-12-31' }), at)?.end).toBe('2026-12-31');
    expect(declarationOf(form({ email: 'a@example.com', end: 'date', date: '2026-12-31', kind: 'extraordinary', contract: 'lifetime' }), at))
      .toMatchObject({ end: '2026-12-31', kind: 'extraordinary', contract: 'lifetime' });
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
    const rows = (await db().prepare('SELECT received_at, kind, reason, end_requested, user_id, outcome, ends_at FROM cancellations ORDER BY id').all()).results;
    expect(rows).toEqual([
      { received_at: '2023-01-01T00:00:00.000Z', kind: 'ordinary', reason: null, end_requested: null, user_id: null, outcome: 'no_account', ends_at: null },
      { received_at: at.toISOString(), kind: 'extraordinary', reason: 'r', end_requested: '2026-12-31', user_id: 7, outcome: 'cancelled', ends_at: ENDS },
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

  it('tells Pavel of every declaration, even one for an unknown email, and emails no stranger', async () => {
    await processDeclaration(decl({ email: 'nobody@example.com' }));
    expect(notice().subject).toBe('cancel: no_account: nobody@example.com');
    expect(notice().text).toContain('Account: none under this email');
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
