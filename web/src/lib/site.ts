/**
 * The site's one domain. SHEPETAL_DOMAIN is set once, in wrangler.toml [vars] (read by domain.config.mjs):
 * next.config.ts inlines it at build time (metadata, OG, sitemap), vitest gets it the same way, and the Worker has it
 * at runtime. Every absolute URL the site builds starts with SITE_URL. `.app` is HSTS-preloaded, so it is https only.
 */
export const SHEPETAL_DOMAIN = (process.env.SHEPETAL_DOMAIN ?? '').toLowerCase();
if (!SHEPETAL_DOMAIN) throw new Error('SHEPETAL_DOMAIN is not set (wrangler.toml [vars])');
export const SITE_URL = `https://${SHEPETAL_DOMAIN}`;

/**
 * The host the site lived on before, called by every released app build (API base URL, sign-in, update feed).
 * It is no longer a site: every request there is a 301 to SHEPETAL_DOMAIN (see hostRedirect).
 */
export const LEGACY_HOST = 'shepetal.backant.io';

/**
 * Where a request on another host than SHEPETAL_DOMAIN goes (the custom Worker entry, worker.ts, asks before Next):
 * - www.<domain>: 301 to the apex, same path and query;
 * - the legacy host: every path, /api/* included, is a 301 to the same path and query on SHEPETAL_DOMAIN (Pavel,
 *   22.10.26). Stripe does not follow redirects, so its webhook endpoint must point at the domain itself; old app
 *   builds may drop the Authorization header on the cross-host redirect (accepted: installing a current build fixes it);
 * - any other host (the domain itself, workers.dev previews, localhost): null, served as it is.
 */
export function hostRedirect(url: URL, domain: string = SHEPETAL_DOMAIN): Response | null {
  const host = url.hostname.toLowerCase();
  const to = () => Response.redirect(`https://${domain}${url.pathname}${url.search}`, 301);
  if (host === `www.${domain}`) return to();
  if (host === LEGACY_HOST) return to();
  return null;
}

/**
 * next-auth reads AUTH_URL for its callback URLs. In production it is SITE_URL, so Google always comes back to the
 * domain, whichever host the sign-in started on. Local runs (next dev, wrangler dev, the e2e) set their own.
 */
export function ensureAuthUrl(env: Record<string, string | undefined> = process.env): string {
  const url = env.AUTH_URL || env.NEXTAUTH_URL || SITE_URL;
  env.AUTH_URL ||= url;
  env.NEXTAUTH_URL ||= url;
  return url;
}
