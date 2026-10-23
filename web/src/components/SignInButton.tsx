import { cookies } from 'next/headers';
import { attribution, attributionQuery } from '@/lib/analytics';
import { signIn, siteUrl } from '@/lib/auth';
import { optedIn, TRIAL_EMAILS_COOKIE, TRIAL_EMAILS_COOKIE_MAX_AGE } from '@/lib/trial-emails';

/** redirectTo with the visitor's ?ref= and utm_* on it (before any #fragment), so the download can name the source. */
export function withAttribution(redirectTo: string, form: FormData | null): string {
  const q = form ? attributionQuery(attribution(form)) : '';
  if (!q) return redirectTo;
  const [path, hash] = redirectTo.split('#');
  return `${path}${path.includes('?') ? `&${q.slice(1)}` : q}${hash === undefined ? '' : `#${hash}`}`;
}

/**
 * The trial emails box (lib/trial-emails.ts) waits in a short-lived cookie for next-auth's signIn callback, which
 * records it once the user row exists. Unticked, any earlier tick is dropped.
 */
export async function keepTrialEmailsChoice(form: FormData): Promise<void> {
  const jar = await cookies();
  if (!optedIn(form)) {
    jar.delete(TRIAL_EMAILS_COOKIE);
    return;
  }
  jar.set(TRIAL_EMAILS_COOKIE, 'yes', {
    path: '/',
    maxAge: TRIAL_EMAILS_COOKIE_MAX_AGE,
    httpOnly: true,
    sameSite: 'lax',
    secure: siteUrl().startsWith('https:'),
  });
}

/**
 * Google sign-in through backant's next-auth setup, then back to `redirectTo` on this site. A real form, so it works
 * without JavaScript. On the landing page, StoryMotion adds the visit's ?ref= and utm_* as hidden fields.
 * `before`: fields shown inside the form, above the button (the trial emails box on /login).
 */
export function SignInButton({
  redirectTo,
  children = 'Continue with Google',
  className = 'btn',
  formClassName,
  before,
}: {
  redirectTo: string;
  children?: React.ReactNode;
  className?: string;
  formClassName?: string;
  before?: React.ReactNode;
}) {
  return (
    <form
      className={formClassName}
      action={async (form: FormData) => {
        'use server';
        await keepTrialEmailsChoice(form);
        await signIn('google', { redirectTo: withAttribution(redirectTo, form) });
      }}
    >
      {before}
      <button type="submit" className={className}>
        {children}
      </button>
    </form>
  );
}
