import { db } from './db';

/**
 * The opt-in to the trial emails (lifecycle.ts): an unchecked box wherever an account, and so the trial, is created or
 * signed in to: the website sign-in (SignIn.tsx, through the cookie below and next-auth's signIn callback) and the app's
 * consent page (consentPage in app-login.ts, POST /app/login). Only users with users.trial_emails_at set get them.
 * Any other sign-in (the native sign-in of PR #290) records it the same way: optedIn(form), then recordTrialEmailsOptIn.
 */

/** The checkbox's form field; checked, it posts "yes". */
export const TRIAL_EMAILS_FIELD = 'trial_emails';
export const TRIAL_EMAILS_LABEL = 'Send me three short emails about my trial.';
export const TRIAL_EMAILS_PRIVACY = '/privacy#trial-emails';

/** Whether the posted form has the box ticked. */
export const optedIn = (form: FormData | URLSearchParams | null | undefined) => form?.get(TRIAL_EMAILS_FIELD) === 'yes';

/**
 * The website sign-in goes through Google, so the tick waits in this cookie until next-auth's signIn callback, where
 * the user row exists. Ten minutes, httpOnly, and read only by the callback.
 */
export const TRIAL_EMAILS_COOKIE = 'trial-emails';
export const TRIAL_EMAILS_COOKIE_MAX_AGE = 600;

/**
 * Records the consent for `email` (an existing user), at `now`. Ticking the box again after unsubscribing is a new
 * consent: the unsubscribe is lifted and the time is the new one. False if no such user.
 */
export async function recordTrialEmailsOptIn(email: string, now = Date.now()): Promise<boolean> {
  const user = await db()
    .prepare('UPDATE users SET trial_emails_at = ?2 WHERE email = ?1 RETURNING id')
    .bind(email.trim().toLowerCase(), new Date(now).toISOString())
    .first<{ id: number }>();
  if (!user) return false;
  await db().prepare('DELETE FROM email_unsubscribes WHERE user_id = ?1').bind(user.id).run();
  return true;
}
