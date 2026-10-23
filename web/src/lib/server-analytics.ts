import { analyticsConfig, attribution, attributionQuery, capture, visitorId, type Props } from './analytics';
import { isAllowedRedirect } from './app-login';
import { deviceType, isBot, osFamily } from './user-agent';

// What worker.ts counts of the pages it answers, on the server, so no analytics code runs in the browser and the site
// needs no consent banner (§ 25 TDDDG; Pavel, 22.10.26):
// - $pageview: a GET of an HTML page that answers 200 or 404, by a browser (no bot or link preview), never the RSC
//   payloads, router prefetches, assets, the API, the releases or the app sign-in;
// - app_login_opened: the app opens GET /app/login (redirect_uri shepetal://auth or the loopback), counted once: the
//   return from Google and the "Not you?" link come back with Sec-Fetch-Site set and are not counted again;
// - app_login_consented: the consent POST that redirects to the app with a code.
// All under the anonymous daily visitor id (v_…), never the account. The decision is a few header reads on the
// request path; the id, the properties and the send happen in waitUntil, after the answer has gone. A User-Agent
// gives only the device type and the OS family; a Referer only its host; no IP is sent and $geoip_disable is set.

type Env = { POSTHOG_KEY?: string; POSTHOG_HOST?: string; DB: D1Database };
type Event = '$pageview' | 'app_login_opened' | 'app_login_consented';

/** Counts what `res` answered to `req`, if it is a page view or an app sign-in step. Never touches the response. */
export function serverEvents(req: Request, url: URL, res: Response, env: Env, ctx: Pick<ExecutionContext, 'waitUntil'>): void {
  if (!analyticsConfig(env).key) return;
  const event = eventOf(req, url, res);
  if (event) ctx.waitUntil(send(event, req, url, res, env));
}

/** Which event this request is, or null. Header reads and one or two regular expressions: microseconds. */
export function eventOf(req: Request, url: URL, res: Response): Event | null {
  const path = url.pathname;
  const ua = req.headers.get('user-agent');
  if (path === '/app/login') {
    if (req.method === 'POST') return res.status === 302 && isAllowedRedirect(redirectOf(res)) ? 'app_login_consented' : null;
    const site = req.headers.get('sec-fetch-site');
    const fromApp = (!site || site === 'none') && !url.searchParams.has('switch');
    return req.method === 'GET' && res.status < 400 && fromApp && isAllowedRedirect(url.searchParams.get('redirect_uri') ?? '') && !isBot(ua)
      ? 'app_login_opened'
      : null;
  }
  if (req.method !== 'GET' || (res.status !== 200 && res.status !== 404)) return null;
  if (!(res.headers.get('content-type') ?? '').startsWith('text/html')) return null;
  const h = req.headers;
  if (h.has('rsc') || h.has('next-router-prefetch') || url.searchParams.has('_rsc')) return null;
  if ((h.get('sec-purpose') ?? h.get('purpose') ?? '').includes('prefetch')) return null;
  if (/^\/(api|_next|app|download)(\/|$)|^\/appcast\.xml$|\.\w+$/.test(path)) return null;
  return isBot(ua) ? null : '$pageview';
}

/** The redirect_uri a consent answer sends the browser to (its Location without the code and state). */
const redirectOf = (res: Response) => (res.headers.get('location') ?? '').split('?')[0];

/** The Referer's host only ("$direct" without one), never the page it came from. */
export function referrerHost(referer: string | null): string {
  if (!referer) return '$direct';
  try {
    return new URL(referer).hostname || '$direct';
  } catch {
    return '$direct';
  }
}

/** The app's version, when the request carries one (?app_version= or a "shepetal/<v>" user agent). */
function appVersion(req: Request, url: URL): string | undefined {
  const v = url.searchParams.get('app_version') ?? req.headers.get('user-agent')?.match(/^shepetal\/([\w.+-]{1,32})/i)?.[1];
  return v && /^[\w.+-]{1,32}$/.test(v) ? v : undefined;
}

async function send(event: Event, req: Request, url: URL, res: Response, env: Env): Promise<void> {
  try {
    const id = await visitorId(req, Date.now(), env.DB);
    const ua = req.headers.get('user-agent') ?? '';
    const props: Props = { $device_type: deviceType(ua), $os: osFamily(ua) };
    if (event === '$pageview') {
      const a = attribution(url.searchParams);
      // Only ref and utm_* of the query: the rest could be anything (a state, a code, an email).
      Object.assign(props, { $current_url: `${url.origin}${url.pathname}${attributionQuery(a)}`, $host: url.host, $pathname: url.pathname, path: url.pathname, ...a });
      props.$referring_domain = referrerHost(req.headers.get('referer'));
      if (res.status === 404) props.status = 404;
    } else {
      const redirect = event === 'app_login_opened' ? (url.searchParams.get('redirect_uri') ?? '') : redirectOf(res);
      props.client = redirect === 'shepetal://auth' ? 'app' : 'loopback';
      props.app_version = appVersion(req, url);
      // Whether a site session already existed, as a yes or no: never which account.
      if (event === 'app_login_opened') props.signed_in = (req.headers.get('cookie') ?? '').includes('authjs.session-token=');
    }
    await capture(event, id, props, env);
  } catch {
    // An id that cannot be made (D1 down) drops the event, never the answer.
  }
}
