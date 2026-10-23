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
            {/* A real form, so it works without JavaScript: Google sign-in (lib/auth.ts), then back to `next`. worker.ts
                sets the action's callbackUrl to the visit's ?next= and shows the alert on ?error: attributes only, which
                hydration leaves alone (a hidden input's value it would reset to the build's). */}
            <form className="s-form" method="post" action={`/api/auth/signin/google?callbackUrl=${encodeURIComponent(next)}`}>
              <button type="submit" className="s-btn s-btn-signal">
                Continue with Google
              </button>
            </form>
            <p role="alert" className="s-alert" hidden={!failed}>
              Sign-in did not finish. Try again.
            </p>
          </div>
          <p className="s-mono">For Mac</p>
        </div>
      </main>
    </>
  );
}
