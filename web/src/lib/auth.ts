import NextAuth from 'next-auth';
import { cookies } from 'next/headers';
import Google from 'next-auth/providers/google';
import { upsertUser, type User } from './account';
import { ensureAuthUrl, SITE_URL } from './site';
import { bearer, userForToken } from './tokens';
import { recordTrialEmailsOptIn, TRIAL_EMAILS_COOKIE } from './trial-emails';

// Same Google OAuth client and next-auth setup as backant.io: JWT sessions, no adapter.
// Cookies stay host-only, so a shepetal session never reaches backant.io and the reverse.
// Lazy config: env and the D1 binding only exist inside a request on the Worker.
// AUTH_URL is SITE_URL in production (src/lib/site.ts), set here before next-auth reads it, so Google always comes
// back to the domain. Local runs set their own AUTH_URL.
export const { handlers, auth, signIn, signOut } = NextAuth(() => {
  ensureAuthUrl();
  return {
    providers: [
      Google({
        clientId: process.env.GOOGLE_CLIENT_ID,
        clientSecret: process.env.GOOGLE_CLIENT_SECRET,
      }),
    ],
    callbacks: {
      async signIn({ user, profile }) {
        if (!user.email || profile?.email_verified === false) return false;
        await upsertUser(user.email); // first shepetal sign-in starts the 30-day trial
        await trialEmailsFromCookie(user.email);
        return true;
      },
    },
    // Our own sign-in page, also for next-auth's errors (a cancelled Google sign-in, a refused account).
    pages: { signIn: '/login', error: '/login' },
    trustHost: true,
  };
});

/** The trial emails box ticked on /login (SignInButton keeps it in a cookie through Google): recorded, then dropped. */
export async function trialEmailsFromCookie(email: string): Promise<void> {
  const jar = await cookies();
  if (jar.get(TRIAL_EMAILS_COOKIE)?.value !== 'yes') return;
  await recordTrialEmailsOptIn(email);
  try {
    jar.delete(TRIAL_EMAILS_COOKIE);
  } catch {
    // Not every caller may change cookies: it expires within 10 minutes anyway.
  }
}

/**
 * The origin links point at (Stripe's return URLs, the app login's Origin check): SITE_URL in production, whichever
 * host the request came to; AUTH_URL in local runs.
 */
export const siteUrl = (_req?: Request) => process.env.AUTH_URL || SITE_URL;

/**
 * The caller of an API route: the app's bearer token if one is sent (an invalid
 * token is null, never a fallback to the cookie), else the web session.
 */
export async function requestUser(req: Request): Promise<User | null> {
  const token = bearer(req);
  if (token) return userForToken(token);
  const email = (await auth())?.user?.email;
  return email ? upsertUser(email) : null;
}
