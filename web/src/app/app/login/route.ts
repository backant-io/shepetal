import { cookies } from 'next/headers';
import { upsertUser } from '@/lib/account';
import { consentPage, issueCode, loginQuery, parseLogin } from '@/lib/app-login';
import { auth, signIn, siteUrl } from '@/lib/auth';
import { randomSecret } from '@/lib/tokens';

// /app/login (API.md): the apps open it in ASWebAuthenticationSession or the browser.
// GET: Google sign-in if needed, then a consent page. Only the consent POST issues a code, so a
// program that opens this URL by itself never gets a code without the user pressing Continue.

const text = (body: string, status: number) =>
  new Response(body, { status, headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' } });
// Double-submit CSRF cookie. __Host- needs https, so a local http run uses a plain name.
const csrfName = (req: Request) => (siteUrl(req).startsWith('https:') ? '__Host-app-login-csrf' : 'app-login-csrf');
const csrfCookie = (req: Request, value: string, maxAge: number) =>
  `${csrfName(req)}=${value}; Path=/; Max-Age=${maxAge}; HttpOnly; SameSite=Lax${siteUrl(req).startsWith('https:') ? '; Secure' : ''}`;

export async function GET(req: Request) {
  const q = new URL(req.url).searchParams;
  const login = parseLogin(q);
  if (!login) return text('Bad sign-in request', 400);
  const back = `/app/login?${loginQuery(login)}`;
  const email = (await auth())?.user?.email;
  if (!email) return signIn('google', { redirectTo: back });
  if (q.has('switch')) return signIn('google', { redirectTo: back }, { prompt: 'select_account' });
  const csrf = randomSecret();
  return new Response(consentPage(email, login, csrf), {
    headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', 'set-cookie': csrfCookie(req, csrf, 600) },
  });
}

export async function POST(req: Request) {
  const form = await req.formData().catch(() => null);
  const fields = new URLSearchParams();
  form?.forEach((v, k) => typeof v === 'string' && fields.append(k, v));
  const login = parseLogin(fields);
  if (!login) return text('Bad sign-in request', 400);
  const sent = fields.get('csrf');
  const kept = (await cookies()).get(csrfName(req))?.value;
  if (req.headers.get('origin') !== new URL(siteUrl(req)).origin || !sent || sent !== kept) return text('Forbidden', 403);
  const email = (await auth())?.user?.email;
  if (!email) return text('Signed out: start again from the app', 401);
  const user = await upsertUser(email); // first sign-in starts the trial
  return new Response(null, {
    status: 302,
    headers: { location: await issueCode(user.email, login), 'cache-control': 'no-store', 'set-cookie': csrfCookie(req, '', 0) },
  });
}
