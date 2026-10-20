import NextAuth from 'next-auth';
import Google from 'next-auth/providers/google';
import { upsertUser } from './account';

// Same Google OAuth client and next-auth setup as backant.io: JWT sessions, no adapter.
// Cookies stay host-only, so a shepetal session never reaches backant.io and the reverse.
// Lazy config: env and the D1 binding only exist inside a request on the Worker.
export const { handlers, auth, signIn, signOut } = NextAuth(() => ({
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
}));
