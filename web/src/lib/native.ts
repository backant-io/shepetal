import { securityHeaders } from '../../security-headers.mjs';

// What worker.ts wraps around everything it answers itself: the security headers, and an exception turned into the
// site's own 500 instead of Cloudflare's 1101 error page (which shows the Worker's name and says the script threw).

/** An exception's class name for a log line (TypeError, Error…): its message may carry what it was given. */
export const errorName = (e: unknown) => (e instanceof Error ? e.name || 'Error' : typeof e).replace(/[^\w.-]/g, '').slice(0, 40);

/** `res` with the security headers. A copy: Response.redirect() (the billing portal link) has immutable headers. */
export function secured(res: Response): Response {
  const out = new Response(res.body, res);
  for (const { key, value } of securityHeaders()) out.headers.set(key, value);
  return out;
}

/**
 * The 500 for an exception: no stack, no message, not stored by anyone (an API's as JSON, a page's as text), logged
 * with the route and the exception's class name only. Stripe retries a webhook answered 500.
 */
export function serverError(route: string, e: unknown, api: boolean): Response {
  console.error(`${route}: 500 (${errorName(e)})`);
  const headers = { 'cache-control': 'no-store' };
  return api
    ? Response.json({ error: 'server_error' }, { status: 500, headers })
    : new Response('Something went wrong on our side. Try again in a minute.', { status: 500, headers: { ...headers, 'content-type': 'text/plain; charset=utf-8' } });
}

/**
 * What `run` answers, or serverError() with the security headers if it throws. `route` is the method and the path
 * pattern, never the URL (a path or query may carry anything).
 */
export async function guarded(route: string, api: boolean, run: () => Promise<Response>): Promise<Response> {
  try {
    return await run();
  } catch (e) {
    return secured(serverError(route, e, api));
  }
}
