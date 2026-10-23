import { db } from './db';

/**
 * The opt-in to the trial emails (lifecycle.ts): an unchecked box wherever an account, and so the trial, is created or
 * signed in to: the website sign-in (SignIn.tsx; the tick rides through Google in the sealed sign-in cookie and
 * googleCallback in auth.ts records it) and the app's consent page (consentPage in app-login.ts, POST /app/login).
 * Only users with users.trial_emails_at set get them. Both read the form with optedIn, then recordTrialEmailsOptIn.
 */

/** The checkbox's form field; checked, it posts "yes". */
export const TRIAL_EMAILS_FIELD = 'trial_emails';
export const TRIAL_EMAILS_LABEL = 'Send me three short emails about my trial.';
export const TRIAL_EMAILS_PRIVACY = '/privacy#trial-emails';

/** Whether the posted form has the box ticked. */
export const optedIn = (form: FormData | URLSearchParams | null | undefined) => form?.get(TRIAL_EMAILS_FIELD) === 'yes';

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
