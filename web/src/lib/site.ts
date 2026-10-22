/**
 * shepetal's own domain, set in ONE place: SHEPETAL_DOMAIN in wrangler.toml [vars]. The Worker gets it at runtime,
 * and next.config.ts inlines the same value at build time (for metadataBase, OG and canonical URLs). Every absolute
 * URL the site builds starts from here: auth callbacks, Stripe success, cancel and portal return URLs, OG, sitemap,
 * canonical, /appcast.xml. Never write the domain anywhere else.
 */
export function siteDomain(): string {
  const d = process.env.SHEPETAL_DOMAIN;
  if (!d) throw new Error('SHEPETAL_DOMAIN is not set (wrangler.toml [vars])');
  return d;
}

/** https://<SHEPETAL_DOMAIN>, no trailing slash. */
export const siteOrigin = () => `https://${siteDomain()}`;
