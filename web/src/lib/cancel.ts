import { renewingSubscription, userByEmail } from './account';
import { db } from './db';
import { cancelAt, setCancelAtPeriodEnd } from './stripe';

/**
 * A cancellation sent with the "Jetzt kündigen" button on /cancel (§ 312k BGB): the fields of the form, as declared.
 * The button and the page need no sign-in.
 */
export type Declaration = {
  kind: 'ordinary' | 'extraordinary';
  /** For an extraordinary cancellation: the good cause. */
  reason: string;
  contract: 'monthly' | 'lifetime';
  /** The requested end (YYYY-MM-DD), or null: as soon as possible. */
  end: string | null;
  email: string;
  /** When it came in, which counts as when it was sent (§ 312k(4)). */
  at: Date;
};

export const KIND = { ordinary: 'Ordinary cancellation', extraordinary: 'Extraordinary cancellation for good cause' };
export const CONTRACT = { monthly: 'shepetal monthly subscription', lifetime: 'shepetal lifetime license' };
export const ASAP = 'As soon as possible, at the end of the month already paid';

/** The form as posted, or null without an email (the one required field). */
export function declarationOf(form: FormData, at = new Date()): Declaration | null {
  const field = (k: string) => String(form.get(k) ?? '').trim();
  const email = field('email').slice(0, 254);
  if (!/^[^\s@]+@[^\s@]+$/.test(email)) return null;
  const date = field('date');
  return {
    kind: field('kind') === 'extraordinary' ? 'extraordinary' : 'ordinary',
    reason: field('reason').slice(0, 2000),
    contract: field('contract') === 'lifetime' ? 'lifetime' : 'monthly',
    // An "On this date" without a date ends it as soon as possible (§ 312k(5)).
    end: field('end') === 'date' && /^\d{4}-\d{2}-\d{2}$/.test(date) && !isNaN(Date.parse(date)) ? date : null,
    email,
    at,
  };
}

/** "2026-10-22 at 14:03:05 UTC" */
export const utc = (d: Date) => `${d.toISOString().slice(0, 10)} at ${d.toISOString().slice(11, 19)} UTC`;

/**
 * The confirmation: what was declared, when it came in and when the contract is to end (§ 312k(3) and (4)). The
 * receipt page shows it and offers it as a file to keep.
 */
export function confirmationText(d: Declaration): string {
  return [
    'Cancellation (Kündigung)',
    '',
    `Sent with the "Jetzt kündigen" button on shepetal.app on ${utc(d.at)}.`,
    `Received by BackAnt, Inc. on ${utc(d.at)}.`,
    '',
    `Type: ${KIND[d.kind]}`,
    ...(d.kind === 'extraordinary' ? [`Reason: ${d.reason || '(none given)'}`] : []),
    `Contract: ${CONTRACT[d.contract]}`,
    `End of the contract: ${d.end ? `on ${d.end}` : ASAP}`,
    `Email of the account: ${d.email}`,
    '',
    'To: BackAnt, Inc., 131 Continental Dr, Suite 305, Newark, DE 19713, USA (shepetal), support@shepetal.app',
  ].join('\n');
}

/**
 * Acts on a declaration: a renewing monthly subscription under that email stops renewing, at the end of the paid
 * month, or at a requested date after it. Anything else (a lifetime license, no subscription, no account) is only
 * recorded. The result is for the record and the log, never for the sender: the page is the same either way, so it
 * tells no one which emails have an account.
 */
export async function cancelContract(d: Declaration): Promise<{ userId: number | null; outcome: string }> {
  const user = await userByEmail(d.email);
  if (!user) return { userId: null, outcome: 'no_account' };
  if (d.contract !== 'monthly' || !renewingSubscription(user)) return { userId: user.id, outcome: 'no_subscription' };
  const end = d.end ? Date.parse(`${d.end}T23:59:59Z`) : 0;
  if (user.paid_through && end > Date.parse(user.paid_through)) {
    await cancelAt(user, Math.floor(end / 1000));
    return { userId: user.id, outcome: 'cancel_at' };
  }
  await setCancelAtPeriodEnd(user, true);
  return { userId: user.id, outcome: 'cancelled_at_period_end' };
}

/** Keeps the declaration, and deletes those older than three years after the end of their year. */
export async function recordCancellation(d: Declaration, userId: number | null, outcome: string): Promise<void> {
  await db().batch([
    db().prepare('DELETE FROM cancellations WHERE received_at < ?1').bind(`${d.at.getUTCFullYear() - 3}-01-01`),
    db()
      .prepare(
        `INSERT INTO cancellations (received_at, email, kind, reason, contract, end_requested, user_id, outcome)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
      )
      .bind(d.at.toISOString(), d.email.toLowerCase(), d.kind, d.reason || null, d.contract, d.end, userId, outcome),
  ]);
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

/** The answer to the button: the confirmation, with the time it was sent, as a page and as a file to keep (§ 312k(3)). */
export function receiptHtml(d: Declaration): string {
  const text = confirmationText(d);
  const file = `shepetal-cancellation-${d.at.toISOString().slice(0, 10)}.txt`;
  return page(
    'Cancellation sent',
    `<h1>Your cancellation is sent.</h1>
<p class="mono">Sent with the Jetzt kündigen button on ${utc(d.at)}.</p>
<pre>${esc(text)}</pre>
<p><a href="data:text/plain;charset=utf-8,${encodeURIComponent(text)}" download="${file}">Download this confirmation</a> (${file}). Keep it: it shows what you sent and when.</p>
<p>If you chose the monthly subscription and this email has one, it stops renewing. It ends at the end of the month already paid, or on the date you chose if that is later, and nothing is charged after it ends.</p>
<p>Questions: <a href="mailto:support@shepetal.app">support@shepetal.app</a></p>`,
  );
}

/** The form came without an email (a browser that skipped the required field). */
export const missingEmailHtml = () =>
  page('Cancel your contract', '<h1>Enter your email.</h1><p>The email of your shepetal account is needed to find your contract. <a href="/cancel">Back to the form</a></p>');
