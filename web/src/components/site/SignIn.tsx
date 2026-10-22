import { SignInButton } from '@/components/SignInButton';
import { SiteHeader } from './Shell';
import { SmallKey } from './SmallKey';

/**
 * Sign-in, in the landing page's system: the hero's composition, the key kept small, and one action.
 * Continue with Google is the page's only orange.
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
            <SignInButton redirectTo={next} className="s-btn s-btn-signal" formClassName="s-form">
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
