import { userByEmail, type User } from './account';
import { db } from './db';
import { OWNER, sendMail, sesEnabled } from './mail';
import { SITE_URL } from './site';
import { cancelAt } from './stripe';

/**
 * A cancellation sent with the "Jetzt kündigen" button on /cancel (§ 312k BGB): the fields of the form, as declared.
 * The button and the page need no sign-in.
 */
export type Declaration = {
  kind: 'ordinary' | 'extraordinary';
  /** For an extraordinary cancellation: the good cause. */
  reason: string;
  contract: 'monthly' | 'lifetime';
  /** The requested end (YYYY-MM-DD, a day after the one it was sent on), or null: as soon as possible. */
  end: string | null;
  /** "Right away" was chosen: for an extraordinary cancellation, an end now (decided by hand); else as soon as possible. */
  now: boolean;
  /** A date that was entered but is not a later day (past, today, or no such day): it ends as soon as possible. */
  badDate: string | null;
  email: string;
  /** When it came in, which counts as when it was sent (§ 312k(4)). */
  at: Date;
};

export const KIND = { ordinary: 'Ordinary cancellation', extraordinary: 'Extraordinary cancellation for good cause' };
export const CONTRACT = { monthly: 'shepetal monthly subscription', lifetime: 'shepetal lifetime license' };
export const ASAP = 'As soon as possible, at the end of the period already paid';
export const RIGHT_AWAY = 'Right away, for an extraordinary cancellation';
/** How far a requested date may be: the end then is that date, at most three months after the period already paid. */
export const DATE_RULE = 'not before the end of the period already paid, and at most three months after it';

const day = (d: Date) => d.toISOString().slice(0, 10);

/** The form as posted, or null without an email (the one required field). */
export function declarationOf(form: FormData, at = new Date()): Declaration | null {
  const field = (k: string) => String(form.get(k) ?? '').trim();
  const email = field('email').slice(0, 254);
  if (!/^[^\s@]+@[^\s@]+$/.test(email)) return null;
  // An explicit "as soon as possible" or "right away" wins over a date left in the field (§ 312k(5)). Otherwise a date
  // filled in counts. It must be a real day after today (2026-02-31 parses, but is no day); anything else ends it as
  // soon as possible, and the receipt says so.
  const choice = field('end');
  const date = choice === 'asap' || choice === 'now' ? '' : field('date').slice(0, 10);
  const real = /^\d{4}-\d{2}-\d{2}$/.test(date) && !isNaN(Date.parse(date)) && day(new Date(date)) === date;
  const end = real && date > day(at) ? date : null;
  return {
    kind: field('kind') === 'extraordinary' ? 'extraordinary' : 'ordinary',
    reason: field('reason').slice(0, 2000),
    contract: field('contract') === 'lifetime' ? 'lifetime' : 'monthly',
    end,
    now: choice === 'now',
    badDate: date && !end ? date : null,
    email,
    at,
  };
}

/** "2026-10-22 at 14:03:05 UTC" */
export const utc = (d: Date) => `${d.toISOString().slice(0, 10)} at ${d.toISOString().slice(11, 19)} UTC`;

/**
 * Text someone typed, as it may go back to a customer: at most `max` characters, with anything that looks like a link
 * taken out. Anyone who knows an account's email can fill in the form, and support@shepetal.app must never carry
 * their link to the account's owner.
 */
export const plain = (s: string, max = 40) =>
  s
    .slice(0, max)
    .replace(/\b[a-z][a-z0-9+.-]*:\/*\S*/gi, '[link removed]')
    .replace(/\S*\b(?:[a-z0-9-]+\.)+[a-z]{2,}\b\S*/gi, '[link removed]');

/**
 * What was sent, and when (§ 312k(3)): the receipt page shows it and offers it as a file to keep, and Pavel's notice
 * carries it. `to` 'customer' is the copy in the email to the account: never the reason as typed (anyone who knows the
 * email can type it, and support@shepetal.app would deliver it, a phishing channel), and no links in the date.
 */
export function declarationText(d: Declaration, to: 'sender' | 'customer' = 'sender'): string {
  const end =
    d.now && d.kind === 'extraordinary'
      ? RIGHT_AWAY
      : d.now
        ? `${ASAP} (right away is for an extraordinary cancellation)`
        : d.end
          ? `${d.end}, ${DATE_RULE}`
          : d.badDate
            ? `${ASAP} (the date entered, ${to === 'customer' ? plain(d.badDate, 10) : d.badDate}, is not a day after today)`
            : ASAP;
  const reason = to === 'customer' ? 'as entered on the form' : d.reason || '(none given)';
  return [
    'Cancellation (Kündigung)',
    '',
    `Sent with the "Jetzt kündigen" button on shepetal.app on ${utc(d.at)}.`,
    `Received by BackAnt, Inc. on ${utc(d.at)}.`,
    '',
    `Type: ${KIND[d.kind]}`,
    ...(d.kind === 'extraordinary' ? [`Reason: ${reason}`] : []),
    `Contract: ${CONTRACT[d.contract]}`,
    `End of the contract: ${end}`,
    `Email of the account, for the confirmation: ${d.email}`,
    '',
    'To: BackAnt, Inc., 131 Continental Dr, Suite 305, Newark, DE 19713, USA (shepetal), support@shepetal.app',
  ].join('\n');
}

/** What was done about a declaration. Never thrown: a failure is outcome 'error' with the message. */
export type Handling = {
  /** The account under the email, matched lowercased (never created). */
  user: User | null;
  outcome: 'cancelled' | 'already_ending' | 'no_subscription' | 'lifetime' | 'no_account' | 'error';
  /** When the subscription ends, as Stripe has it (ISO). */
  endsAt: string | null;
  error: string | null;
};

const message = (e: unknown) => (e instanceof Error ? e.message : String(e));

/**
 * Acts on a declaration: a live subscription under that email ends at the end of the paid period, or on the date
 * asked for (stripe.ts cancelAt caps it and never moves an end later). Whatever contract was chosen: an account has
 * one or the other, and a subscriber who picks "lifetime license" still means the subscription (§§ 133, 157 BGB).
 * An extraordinary cancellation stops the renewal the same way; Pavel decides about ending it at once (his notice).
 */
export async function cancelContract(d: Declaration): Promise<Handling> {
  let user: User | null = null;
  try {
    user = await userByEmail(d.email);
    if (!user) return { user, outcome: 'no_account', endsAt: null, error: null };
    const ended = await cancelAt(user, d.end ? Date.parse(`${d.end}T23:59:59Z`) / 1000 : null);
    if (ended) return { user, outcome: ended.changed ? 'cancelled' : 'already_ending', endsAt: ended.ends_at, error: null };
    return { user, outcome: user.status === 'active' ? 'lifetime' : 'no_subscription', endsAt: null, error: null };
  } catch (e) {
    return { user, outcome: 'error', endsAt: null, error: message(e) };
  }
}

/** Keeps the declaration, and deletes those older than three years after the end of their year. */
export async function recordCancellation(d: Declaration, h: Handling): Promise<void> {
  await db().batch([
    db().prepare('DELETE FROM cancellations WHERE received_at < ?1').bind(`${d.at.getUTCFullYear() - 3}-01-01`),
    db()
      .prepare(
        `INSERT INTO cancellations (received_at, email, kind, reason, contract, end_requested, user_id, outcome, ends_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)`,
      )
      .bind(d.at.toISOString(), d.email.toLowerCase(), d.kind, d.reason || null, d.contract, d.now ? 'now' : d.end, h.user?.id ?? null, h.outcome, h.endsAt),
  ]);
}

/**
 * The § 312k(4) confirmation to the account's email: the declaration, when it came in, and when the contract ends.
 * It states an end only once Stripe has it: after a failure it says the cancellation will be processed. An end after
 * the paid period means one more, shorter charge (Stripe prorates the last renewal), and it says so. "Right away" for
 * good cause is decided by hand, so it names no end but the latest one.
 */
export function confirmationText(d: Declaration, h: Handling): string {
  const ends = h.endsAt && utc(new Date(h.endsAt));
  const paid = h.user?.paid_through;
  const lastCharge = paid && h.endsAt && Date.parse(h.endsAt) > Date.parse(paid) ? paid : null;
  const rightAway = d.now && d.kind === 'extraordinary';
  const done =
    h.outcome === 'cancelled' || h.outcome === 'already_ending'
      ? [
          rightAway
            ? `Your subscription no longer renews, so it ends on ${ends} at the latest. You asked for it to end right away, for good cause: we look at your reason, decide when it ends and what is refunded, and write to you.`
            : lastCharge
              ? `Your subscription is cancelled. It ends on ${ends}. On ${utc(new Date(lastCharge))} it is charged once more, only for the days up to that end. Nothing is charged after that.`
              : `Your subscription is cancelled. It ends on ${ends}, and nothing is charged after that.`,
          ...(d.contract === 'lifetime' ? ['You chose the lifetime license, but this account has the monthly subscription, so the subscription is what ends.'] : []),
          ...(d.kind === 'extraordinary' && !rightAway ? ['You cancelled for good cause: we look at your reason and write to you whether it ends earlier and what is refunded.'] : []),
          '',
          `If you did not send this, sign in at ${SITE_URL}/account and choose Resume subscription before ${ends}, or reply to this email.`,
        ]
      : h.outcome === 'lifetime'
        ? ['Your lifetime license has no term and nothing renews, so nothing more is charged. We write to you about your cancellation.']
        : h.outcome === 'no_subscription'
          ? ['This account has no subscription that renews, so nothing is charged and there was nothing to end.']
          : ['Your cancellation is received and will be processed. We confirm the date your contract ends in a separate email.'];
  return [declarationText(d, 'customer'), '', ...done, '', 'BackAnt, Inc. (shepetal), support@shepetal.app'].join('\n');
}

/**
 * Runs after the answer has gone (POST /api/cancel's waitUntil), so the answer takes as long for every email: the
 * lookup, Stripe, the record, the confirmation to the account (SES, when set up) and Pavel's notice of every
 * declaration with what happened. Never throws.
 */
export async function processDeclaration(d: Declaration): Promise<void> {
  const h = await cancelContract(d);
  const problems = h.error ? [`acting on it failed: ${h.error}`] : [];
  try {
    await recordCancellation(d, h);
  } catch (e) {
    problems.push(`recording it in D1 failed: ${message(e)}`);
  }
  const confirmation = confirmationText(d, h);
  let sent = 'not sent: no account under this email (UNMATCHED)';
  if (h.user && !sesEnabled()) sent = `not sent: SES is not set up. Send the text below to ${h.user.email} by hand.`;
  else if (h.user) {
    try {
      // To the account's own address, never one a stranger typed: the match was on it.
      await sendMail(h.user.email, 'Your cancellation of shepetal (Kündigungsbestätigung)', confirmation);
      sent = `sent to ${h.user.email}`;
    } catch (e) {
      problems.push(`the confirmation email failed: ${message(e)}`);
      sent = `FAILED. Send the text below to ${h.user.email} by hand.`;
    }
  }
  for (const p of problems) console.error(`cancel: ${p}`);
  const todo = [
    ...(h.outcome === 'error' ? ['Cancel it by hand in Stripe: the subscription may still renew.'] : []),
    ...(d.kind === 'extraordinary' ? [`Extraordinary${d.now ? ', asked to end right away' : ''}: decide whether it ends at once and what is refunded, and tell the customer.`] : []),
    ...(h.outcome === 'no_account' ? ['UNMATCHED: no account has this email, so nothing was done and no one was emailed. If the person writes, answer by hand.'] : []),
    ...(h.outcome === 'lifetime' ? ['Lifetime license: decide what the customer wants (a refund within 14 days?) and reply.'] : []),
  ];
  const notice = [
    `A cancellation came in through /cancel: ${h.outcome}${h.endsAt ? `, ends ${utc(new Date(h.endsAt))}` : ''}.`,
    '',
    `Account: ${h.user ? `#${h.user.id}, ${h.user.email}, plan ${h.user.plan ?? 'trial'}${h.user.sub_id ? `, ${h.user.sub_id} (${h.user.sub_status})` : ''}` : 'UNMATCHED, none under this email'}`,
    `Confirmation to the customer: ${sent}`,
    ...problems.map((p) => `PROBLEM: ${p}`),
    ...todo.map((t) => `TO DO: ${t}`),
    '',
    '--- The declaration ---',
    declarationText(d),
    ...(h.user ? ['', '--- The confirmation ---', confirmation] : []),
  ].join('\n');
  const flags = [h.outcome === 'no_account' && 'UNMATCHED', d.kind === 'extraordinary' && 'extraordinary', problems.length && 'PROBLEM'].filter(Boolean).join(', ');
  try {
    await sendMail(OWNER, `cancel: ${h.outcome}${flags ? ` (${flags})` : ''}: ${d.email}`.slice(0, 200), notice);
  } catch (e) {
    console.error(`cancel: the notice to ${OWNER} failed: ${message(e)}`);
  }
}

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

/** A page of its own (the API answers it, not Next): the site's ground, ink and fonts, nothing loaded but the fonts. */
function page(title: string, body: string): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex"><title>${esc(title)} - shepetal</title><style>
@font-face{font-family:Archivo;src:url(/fonts/archivo-latin.woff2) format('woff2');font-weight:100 900;font-display:swap}
@font-face{font-family:'Fragment Mono';src:url(/fonts/fragment-mono-latin.woff2) format('woff2');font-display:swap}
@font-face{font-family:'Bodoni Moda';src:url(/fonts/bodoni-moda-italic-latin.woff2) format('woff2');font-style:italic;font-weight:400 900;font-display:swap}
body{margin:0;padding:0 clamp(16px,4vw,56px) 4rem;background:#E6E4DE;color:#161512;font:400 1.0625rem/1.5 Archivo,system-ui,sans-serif}
main{max-width:44rem}a{color:#161512}
.mark{display:inline-block;padding:1.6rem 0;font:italic 500 1.9rem/1 'Bodoni Moda',Georgia,serif;text-decoration:none}
h1{margin:2rem 0 1rem;font-weight:520;font-size:clamp(2.25rem,6vw,4rem);line-height:.97;letter-spacing:-.042em}
.mono,pre{font-family:'Fragment Mono',ui-monospace,monospace;font-size:.8125rem}
pre{white-space:pre-wrap;overflow-wrap:anywhere;padding:1.2rem;border:1px solid rgba(22,21,18,.22);border-radius:4px}
</style></head><body><a class="mark" href="/">shepetal</a><main>${body}</main></body></html>`;
}

/**
 * The answer to the button, before anything is done about it (the same page for every email, at once): the
 * declaration with the time it was sent, as a page and as a file to keep (§ 312k(3)). It never says what was done,
 * since nothing is yet; `ses` says whether a confirmation email will follow.
 */
export function receiptHtml(d: Declaration, ses: boolean): string {
  const text = declarationText(d);
  const file = `shepetal-cancellation-${d.at.toISOString().slice(0, 10)}.txt`;
  return page(
    'Cancellation received',
    `<h1>Your cancellation is received.</h1>
<p class="mono">Sent with the Jetzt kündigen button on ${utc(d.at)}.</p>
<pre>${esc(text)}</pre>
<p><a href="data:text/plain;charset=utf-8,${encodeURIComponent(text)}" download="${file}">Download this cancellation</a> (${file}). Keep it: it shows what you sent and when.</p>
<p>It will be processed now. A subscription under this email ends at the end of the period already paid, or on the date you entered (${DATE_RULE}). With a later date it renews once more, and that last charge covers only the days up to your date. Nothing is charged after it ends. For an extraordinary cancellation right away, we decide when it ends and write to you.</p>
${
  ses
    ? '<p>If this email belongs to a shepetal account, the confirmation, with the date your contract ends, goes to it by email. If none arrives, write to <a href="mailto:support@shepetal.app">support@shepetal.app</a>.</p>'
    : '<p>Confirmation emails are not sent automatically yet, so no email has been sent. Keep this page or the download as your record. If this email belongs to a shepetal account, we confirm the cancellation and the date it ends to it by hand.</p>'
}
<p>Questions: <a href="mailto:support@shepetal.app">support@shepetal.app</a></p>`,
  );
}

/**
 * The throttle's key for an address: an IPv4 address as it is, an IPv6 address by its /64 prefix. One host usually
 * holds a whole /64 and can send from any address in it, so a key per IPv6 address would not limit it at all.
 */
export function ipKey(ip: string): string {
  const a = ip.trim().toLowerCase().split('%')[0];
  if (!a.includes(':')) return a;
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(a);
  if (mapped) return mapped[1];
  // An embedded IPv4 tail (64:ff9b::1.2.3.4) takes the place of two groups.
  const groups = (s: string) => (s ? s.split(':').flatMap((g) => (g.includes('.') ? ['0', '0'] : [g])) : []);
  const [head, tail] = a.split('::');
  const all = tail === undefined ? groups(head) : [...groups(head), ...Array(Math.max(0, 8 - groups(head).length - groups(tail).length)).fill('0'), ...groups(tail)];
  return `${all.slice(0, 4).map((g) => (parseInt(g, 16) || 0).toString(16)).join(':')}::/64`;
}

/** The form came without an email (a browser that skipped the required field). */
export const missingEmailHtml = () =>
  page('Cancel your contract', '<h1>Enter your email.</h1><p>The email of your shepetal account is needed to find your contract. <a href="/cancel">Back to the form</a></p>');

/** Posted from another site, or with no Origin: not received. */
export const otherOriginHtml = () =>
  page('Cancel your contract', `<h1>Send it from the form.</h1><p>This cancellation was not received: it did not come from the form on shepetal.app. <a href="/cancel">Open the form</a>, or write to <a href="mailto:support@shepetal.app">support@shepetal.app</a>.</p>`);

/** More than 5 a minute from one address or for one email: not received. */
export const tooManyHtml = () =>
  page('Cancel your contract', `<h1>Wait a minute.</h1><p>Too many cancellations were sent in a short time, so this one was not received. Wait a minute and send it again from <a href="/cancel">the form</a>, or write to <a href="mailto:support@shepetal.app">support@shepetal.app</a>.</p>`);
