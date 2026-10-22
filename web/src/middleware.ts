import { NextResponse, type NextRequest } from 'next/server';

/**
 * One canonical host: https://<SHEPETAL_DOMAIN>. A page asked for on another host the Worker answers (the old host
 * shepetal.backant.io, kept attached in wrangler.toml so released apps and the current Stripe webhook keep working)
 * moves there with a 301. /api/* answers on every host. A local run (AUTH_URL set) and *.workers.dev are left alone.
 */
export function middleware(req: NextRequest) {
  const domain = process.env.SHEPETAL_DOMAIN;
  const host = req.headers.get('host') ?? '';
  // A local run sets AUTH_URL to its own address. (auth.ts fills AUTH_URL with https://<SHEPETAL_DOMAIN> otherwise.)
  const local = !!process.env.AUTH_URL && new URL(process.env.AUTH_URL).host !== domain;
  if (!domain || local || host === domain || host.endsWith('.workers.dev')) return NextResponse.next();
  const to = new URL(req.nextUrl.pathname + req.nextUrl.search, `https://${domain}`);
  return NextResponse.redirect(to, 301);
}

export const config = { matcher: ['/((?!api/).*)'] };
