import { SignInButton } from '@/components/SignInButton';
import { TRIAL_EMAILS_FIELD, TRIAL_EMAILS_LABEL, TRIAL_EMAILS_PRIVACY } from '@/lib/trial-emails';
import { SiteHeader } from './Shell';
import { SmallKey } from './SmallKey';

/**
 * Sign-in, in the landing page's system: the hero's composition, the key kept small, and one action.
 * Continue with Google is the page's only orange. The trial emails box is unticked: only a tick sends them
 * (lib/trial-emails.ts), and a user already signed up can tick it here on their next sign-in.
 */
export function SignIn({ next = '/account', failed = false }: { next?: string; failed?: boolean }) {
  return (
    <>
      <SiteHeader />
      <main className="s-main s-hero s-press">
        <div>
          <h1 className="s-h1">Sign in.</h1>
          <SmallKey />
        </div>
        <div className="s-hero-side">
          <p className="s-lede s-ink">30 days free.</p>
          <div>
            <SignInButton
              redirectTo={next}
              className="s-btn s-btn-signal"
              formClassName="s-form"
              before={
                <label className="s-check">
                  <input type="checkbox" name={TRIAL_EMAILS_FIELD} value="yes" />
                  {` ${TRIAL_EMAILS_LABEL} `}
                  <a href={TRIAL_EMAILS_PRIVACY}>Privacy</a>
                </label>
              }
            >
              Continue with Google
            </SignInButton>
            {failed && (
              <p role="alert" className="s-alert">
                Sign-in did not finish. Try again.
              </p>
            )}
          </div>
          <p className="s-mono">For Mac</p>
        </div>
      </main>
    </>
  );
}
