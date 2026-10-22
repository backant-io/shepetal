// SHEPETAL_DOMAIN, the site's one domain, lives in wrangler.toml [vars]. next.config.ts, vitest.config.ts and
// scripts/stripe-setup.mjs read it from there, so there is one value to change. An env var overrides it.
import { readFileSync } from 'node:fs';

export function shepetalDomain() {
  if (process.env.SHEPETAL_DOMAIN) return process.env.SHEPETAL_DOMAIN;
  const toml = readFileSync(new URL('./wrangler.toml', import.meta.url), 'utf8');
  const vars = toml.split(/^\[vars\]\s*$/m)[1]?.split(/^\[/m)[0] ?? '';
  const m = vars.match(/^SHEPETAL_DOMAIN\s*=\s*"([^"]+)"/m);
  if (!m) throw new Error('wrangler.toml: [vars] SHEPETAL_DOMAIN is missing');
  return m[1];
}
