#!/usr/bin/env node
// The Worker on its three hostnames (src/lib/site.ts, worker.ts), on the real Worker runtime:
//   shepetal.backant.io (the old host, called by every released app build): /api/* answers directly, never with a
//     redirect; pages, /app/login (with its query) and /appcast.xml are a 301 to the same path on SHEPETAL_DOMAIN;
//   SHEPETAL_DOMAIN: served as it is, and next-auth's callback is on it;
//   www.SHEPETAL_DOMAIN: a 301 to the apex.
// `wrangler dev --local-upstream <host>` makes the Worker see each request as made to <host>, the way the custom
// domain delivers it in production. No secrets: every value is generated per run, and nothing leaves the machine
// except next-auth's Google discovery on /app/login.
//
//   node e2e/hosts.mjs                    # builds the Worker first (opennextjs-cloudflare build)
//   E2E_SKIP_BUILD=1 node e2e/hosts.mjs   # reuses .open-next/
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { createWriteStream, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { shepetalDomain } from '../domain.config.mjs';

const WEB = join(dirname(fileURLToPath(import.meta.url)), '..');
const BIN = join(WEB, 'node_modules/.bin');
const DOMAIN = shepetalDomain();
const SITE = `https://${DOMAIN}`;
const LEGACY = 'shepetal.backant.io';
const tmp = mkdtempSync(join(tmpdir(), 'shepetal-hosts-'));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const freePort = () => new Promise((res) => { const s = createServer().listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => res(port)); }); });
let n = 0;
const ok = (what) => console.log(`ok ${++n} - ${what}`);

if (!process.env.E2E_SKIP_BUILD) {
  execFileSync(join(BIN, 'opennextjs-cloudflare'), ['build'], { cwd: WEB, stdio: ['ignore', 'pipe', 'inherit'] });
  ok('opennextjs-cloudflare build');
}
const state = join(tmp, 'state');
execFileSync(join(BIN, 'wrangler'), ['d1', 'migrations', 'apply', 'DB', '--local', '--persist-to', state], { cwd: WEB, stdio: 'ignore' });
// Production-like: no AUTH_URL, so the site builds every URL from SHEPETAL_DOMAIN.
const envFile = join(tmp, 'hosts.env');
writeFileSync(envFile, `AUTH_SECRET=${randomBytes(32).toString('hex')}\nGOOGLE_CLIENT_ID=hosts-client-id\nGOOGLE_CLIENT_SECRET=hosts-client-secret\nSTRIPE_SECRET_KEY=sk_test_hosts\nSTRIPE_WEBHOOK_SECRET=whsec_${randomBytes(16).toString('hex')}\n`, { mode: 0o600 });

/** Runs `wrangler dev` as if every request came to `host`, and gives `fn` a fetch with no redirect following. */
async function onHost(host, fn) {
  const port = await freePort();
  const base = `http://127.0.0.1:${port}`;
  const log = createWriteStream(join(tmp, `wrangler-${host}.log`));
  const worker = spawn(join(BIN, 'wrangler'), ['dev', '--ip', '127.0.0.1', '--port', String(port), '--inspector-port', String(await freePort()),
    '--local-upstream', host, '--persist-to', state, '--env-file', envFile, '--show-interactive-dev-session=false'],
  { cwd: WEB, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
  worker.stdout.pipe(log);
  worker.stderr.pipe(log);
  try {
    for (let i = 0; ; i++) {
      if (worker.exitCode !== null) throw new Error(`wrangler dev exited with ${worker.exitCode} (${join(tmp, `wrangler-${host}.log`)})`);
      if (await fetch(`${base}/api/license`, { redirect: 'manual' }).catch(() => null)) break;
      if (i > 120) throw new Error('wrangler dev did not answer within 60 s');
      await sleep(500);
    }
    await fn((path, init = {}) => fetch(base + path, { redirect: 'manual', ...init }));
  } finally {
    try { process.kill(-worker.pid, 'SIGTERM'); } catch {}
    await sleep(500);
  }
}
const loc = (r) => r.headers.get('location');

try {
  await onHost(LEGACY, async (get) => {
    for (const [method, path, body] of [['GET', '/api/license'], ['POST', '/api/checkout', '{"plan":"lifetime"}'], ['GET', '/api/account/plan'], ['POST', '/api/billing/cancel']]) {
      const r = await get(path, { method, body, headers: { authorization: 'Bearer not-a-token', 'content-type': 'application/json' } });
      assert.equal(r.status, 401, `${method} ${path} on the old host answers itself`);
      assert.equal(loc(r), null);
    }
    const token = await get('/api/app/token', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' });
    assert.deepEqual([token.status, (await token.json()).error], [400, 'invalid_request']);
    const hook = await get('/api/stripe/webhook', { method: 'POST', headers: { 'stripe-signature': 't=1,v1=00' }, body: '{}' });
    assert.equal(hook.status, 400, 'the webhook answers on the old host (bad signature)');
    const providers = await (await get('/api/auth/providers')).json();
    assert.equal(providers.google.callbackUrl, `${SITE}/api/auth/callback/google`, 'Google comes back to the domain, whichever host asked');
    ok(`${LEGACY}: /api/* answers directly (license, checkout, account/plan, billing/cancel 401; app/token 400; the webhook 400), never a redirect; next-auth's callback is ${SITE}/api/auth/callback/google`);

    const q = '?redirect_uri=shepetal%3A%2F%2Fauth&state=a%20%26b&code_challenge=Bcf0yvSXgLJmUFx3HlAqtTQnYWgJmxzU6E8N9q5PQ5w&code_challenge_method=S256';
    const login = await get(`/app/login${q}`);
    assert.deepEqual([login.status, loc(login)], [301, `${SITE}/app/login${q}`]);
    const feed = await get('/appcast.xml');
    assert.deepEqual([feed.status, loc(feed)], [301, `${SITE}/appcast.xml`]);
    for (const path of ['/', '/account', '/login', '/privacy', '/terms?x=1']) {
      const r = await get(path);
      assert.deepEqual([r.status, loc(r)], [301, `${SITE}${path}`], path);
    }
    ok(`${LEGACY}: /app/login (query kept), /appcast.xml and the pages are a 301 to ${SITE}`);
  });

  await onHost(DOMAIN, async (get) => {
    for (const path of ['/', '/login', '/privacy', '/terms', '/legal']) assert.equal((await get(path)).status, 200, path);
    assert.equal((await get('/api/license')).status, 401);
    const html = await (await get('/')).text();
    assert.match(html, new RegExp(`<link rel="canonical" href="${SITE.replace(/\./g, '\\.')}/?"`), 'the canonical URL is on the domain');
    assert.ok(!html.includes(LEGACY), 'the page never names the old host');
    const q = '?redirect_uri=shepetal%3A%2F%2Fauth&state=s&code_challenge=Bcf0yvSXgLJmUFx3HlAqtTQnYWgJmxzU6E8N9q5PQ5w&code_challenge_method=S256';
    const login = await get(`/app/login${q}`);
    assert.equal(login.status, 307);
    assert.ok(decodeURIComponent(loc(login)).includes(`redirect_uri=${SITE}/api/auth/callback/google`), 'Google sign-in with the callback on the domain');
    ok(`${DOMAIN}: pages 200, /api/* answers, the canonical URL and Google's callback are on ${SITE}`);

    // Pavel's rule: nothing public discloses the source code, its license or where it is hosted. Every page in the
    // sitemap plus the pages it leaves out, as the Worker renders them; the font and emoji license files are
    // third-party notices and are not pages.
    const sitemap = await (await get('/sitemap.xml')).text();
    const paths = [...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => new URL(m[1]).pathname);
    assert.ok(paths.length >= 9, `the sitemap lists the public pages (${paths.length})`);
    for (const path of [...paths, '/install', '/login', '/account', '/robots.txt', '/sitemap.xml']) {
      const r = await get(path);
      assert.equal(r.status, 200, path);
      const page = await r.text();
      const text = page.replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>/g, ' ').replace(/<[^>]+>/g, ' ');
      assert.doesNotMatch(page, /github/i, `${path} names GitHub`);
      assert.doesNotMatch(text, /MIT License|source code|open[- ]source/i, `${path} mentions the source code or its license`);
    }
    ok(`${DOMAIN}: no page names GitHub, the source code, open source or the MIT License (${paths.length} sitemap pages and 5 more)`);
  });

  await onHost(`www.${DOMAIN}`, async (get) => {
    for (const path of ['/', '/terms?x=1', '/app/login?state=s', '/api/license']) {
      const r = await get(path);
      assert.deepEqual([r.status, loc(r)], [301, `${SITE}${path}`], path);
    }
    ok(`www.${DOMAIN}: a 301 to the apex, path and query kept`);
  });
  console.log(`hosts: OK (${n} steps)`);
  rmSync(tmp, { recursive: true, force: true });
} catch (e) {
  console.error(`not ok - ${e.message}\nlogs in ${tmp}`);
  process.exit(1);
}
