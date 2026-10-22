import NextAuth, { type NextAuthConfig } from 'next-auth';
import Google from 'next-auth/providers/google';
import { upsertUser, type User } from './account';
import { siteOrigin } from './site';
import { bearer, userForToken } from './tokens';

// Same Google OAuth client and next-auth setup as backant.io: JWT sessions, no adapter.
// Cookies stay host-only, so a shepetal session never reaches backant.io and the reverse.
// Lazy config: env and the D1 binding only exist inside a request on the Worker.
// AUTH_URL (where Google's callback lands: <origin>/api/auth/callback/google) follows SHEPETAL_DOMAIN; a local run
// or the e2e sets AUTH_URL itself.
export const { handlers, auth, signIn, signOut } = NextAuth(() => {
  process.env.AUTH_URL ||= siteOrigin();
  process.env.NEXTAUTH_URL ||= process.env.AUTH_URL;
  return config();
});

const config = (): NextAuthConfig => ({
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
      return true;
    },
  },
  trustHost: true,
});

/** The site origin links point at: AUTH_URL when a local run sets it, else https://<SHEPETAL_DOMAIN>. */
export const siteUrl = (_req?: Request) => process.env.AUTH_URL || siteOrigin();

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
