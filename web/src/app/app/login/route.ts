import { upsertUser } from '@/lib/account';
import { issueCode, parseLogin } from '@/lib/app-login';
import { auth, signIn } from '@/lib/auth';

// GET /app/login (API.md): the apps open this in ASWebAuthenticationSession or the browser.
// Signed out: Google sign-in, then back here. Signed in: 302 to the app with a one-time code.
export async function GET(req: Request) {
  const url = new URL(req.url);
  const login = parseLogin(url.searchParams);
  if (!login) return new Response('Bad sign-in request', { status: 400 });
  const email = (await auth())?.user?.email;
  if (!email) return signIn('google', { redirectTo: url.pathname + url.search });
  const user = await upsertUser(email); // first sign-in starts the trial
  return new Response(null, { status: 302, headers: { location: await issueCode(user.email, login), 'cache-control': 'no-store' } });
}
