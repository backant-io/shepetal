/** SHEPETAL_DOMAIN from the text of wrangler.toml [vars], the one place the domain is set (src/lib/site.ts). */
export function wranglerDomain(toml: string): string {
  const m = toml.match(/^SHEPETAL_DOMAIN\s*=\s*"([^"]+)"/m);
  if (!m) throw new Error('wrangler.toml has no SHEPETAL_DOMAIN in [vars]');
  return m[1];
}
