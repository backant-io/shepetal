import { upsertUser } from '@/lib/account';
import { consentPage, issueCode, loginQuery, parseLogin } from '@/lib/app-login';
import { sameOrigin, sealFor, sessionEmail, setCookie, startGoogle, unsealFrom } from '@/lib/auth';
import { same } from '@/lib/session';
import { randomSecret } from '@/lib/tokens';
import { optedIn, recordTrialEmailsOptIn } from '@/lib/trial-emails';

// /app/login (API.md): the apps open it in ASWebAuthenticationSession or the browser. Answered by worker.ts (no Next).
// GET: Google sign-in if needed, then a consent page. Only the consent POST issues a code, so a
// program that opens this URL by itself never gets a code without the user pressing Continue.

const text = (body: string, status: number) =>
  new Response(body, { status, headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' } });
// Double-submit CSRF cookie (__Host-app-login-csrf, plain name on http): the form's random value, sealed with the email
// the page showed, so Continue issues a code only for that account.
const CSRF = 'app-login-csrf';

export async function GET(req: Request) {
  const q = new URL(req.url).searchParams;
  const login = parseLogin(q);
  if (!login) return text('Bad sign-in request', 400);
  const back = `/app/login?${loginQuery(login)}`;
  const email = await sessionEmail(req);
  if (!email) return startGoogle(back, 307);
  if (q.has('switch')) return startGoogle(back, 307, 'select_account');
  const csrf = randomSecret();
  return new Response(consentPage(email, login, csrf), {
    headers: {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
      'set-cookie': setCookie(CSRF, await sealFor(CSRF, { c: csrf, e: email }, 600), 600),
    },
  });
}

export async function POST(req: Request) {
  const form = await req.formData().catch(() => null);
  const fields = new URLSearchParams();
  form?.forEach((v, k) => typeof v === 'string' && fields.append(k, v));
  const login = parseLogin(fields);
  if (!login) return text('Bad sign-in request', 400);
  const sent = fields.get('csrf');
  const kept = await unsealFrom(req, CSRF);
  if (!sameOrigin(req) || !sent || typeof kept?.c !== 'string' || !same(sent, kept.c)) return text('Forbidden', 403);
  const email = await sessionEmail(req);
  if (!email) return text('Signed out: start again from the app', 401);
  if (kept.e !== email) return text('Forbidden', 403); // another account signed in since the page was shown
  const user = await upsertUser(email); // first sign-in starts the trial
  if (optedIn(fields)) await recordTrialEmailsOptIn(user.email); // the consent page's unticked trial emails box
  return new Response(null, {
    status: 302,
    headers: { location: await issueCode(user.email, login), 'cache-control': 'no-store', 'set-cookie': setCookie(CSRF, '', 0) },
  });
}
