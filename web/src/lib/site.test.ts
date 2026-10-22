import { readFileSync } from 'node:fs';
import { expect, it } from 'vitest';
import { wranglerDomain } from './wrangler-domain';
import { siteOrigin } from './site';

const toml = readFileSync(new URL('../../wrangler.toml', import.meta.url), 'utf8');

// The domain is ONE value: SHEPETAL_DOMAIN in wrangler.toml. The Custom Domain route must name the same host.
it('sets the domain once, in wrangler.toml, and the Custom Domain route matches it', () => {
  expect(wranglerDomain(toml)).toBe('shepetal.app');
  expect(toml).toMatch(/routes = \[\n  \{ pattern = "shepetal\.app", custom_domain = true \},/);
  expect(toml).not.toMatch(/^(AUTH_URL|NEXTAUTH_URL)\s*=/m);
  process.env.SHEPETAL_DOMAIN = wranglerDomain(toml);
  expect(siteOrigin()).toBe('https://shepetal.app');
});

// No other host is written into the site's code: every URL comes from siteOrigin().
it('writes no other shepetal host and no GitHub address into the site', async () => {
  const { execFileSync } = await import('node:child_process');
  const files = execFileSync('git', ['ls-files', 'src', 'public', 'content'], { cwd: new URL('../..', import.meta.url), encoding: 'utf8' })
    .split('\n')
    .filter((f) => f && !/\.test\.tsx?$|OFL\.txt$|NOTICE\.txt$|\.(png|jpg|ico|woff2?|ttf|otf)$/.test(f));
  for (const f of files) {
    const text = readFileSync(new URL(`../../${f}`, import.meta.url), 'utf8');
    expect(text, f).not.toMatch(/shepetal\.backant\.io/);
    // download.ts reaches the release through GitHub's API on the server; nothing it serves names GitHub.
    if (!f.endsWith('src/lib/download.ts')) expect(text, f).not.toMatch(/https?:\/\/(www\.)?github\.com/i);
  }
});
