// SHEPETAL_DOMAIN, the site's one domain, lives in wrangler.toml [vars]. next.config.ts, vitest.config.ts and
// scripts/stripe-setup.mjs read it from there, so there is one value to change. An env var overrides it.
import { readFileSync } from 'node:fs';

/** A value from wrangler.toml [vars] (an env var of the same name overrides it). */
export function wranglerVar(name) {
  if (process.env[name]) return process.env[name];
  const toml = readFileSync(new URL('./wrangler.toml', import.meta.url), 'utf8');
  const vars = toml.split(/^\[vars\]\s*$/m)[1]?.split(/^\[/m)[0] ?? '';
  const m = vars.match(new RegExp(`^${name}\\s*=\\s*"([^"]+)"`, 'm'));
  if (!m) throw new Error(`wrangler.toml: [vars] ${name} is missing`);
  return m[1];
}

export const shepetalDomain = () => wranglerVar('SHEPETAL_DOMAIN');
