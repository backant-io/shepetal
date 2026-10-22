import { NextRequest } from 'next/server';
import { afterEach, expect, it } from 'vitest';
import { config, middleware } from './middleware';

const req = (url: string) => new NextRequest(url, { headers: { host: new URL(url).host } });
afterEach(() => {
  Reflect.deleteProperty(process.env, "AUTH_URL");
});

it('moves pages on another host to the one domain, with the path, and leaves the domain alone', () => {
  process.env.SHEPETAL_DOMAIN = 'shepetal.app';
  const r = middleware(req('https://shepetal.backant.io/account?purchased=1'));
  expect(r.status).toBe(301);
  expect(r.headers.get('location')).toBe('https://shepetal.app/account?purchased=1');
  expect(middleware(req('https://shepetal.app/account')).headers.get('location')).toBeNull();
  expect(middleware(req('https://shepetal-web.example.workers.dev/')).headers.get('location')).toBeNull();
  // auth.ts fills AUTH_URL with the domain in production: pages on the old host still move.
  process.env.AUTH_URL = 'https://shepetal.app';
  expect(middleware(req('https://shepetal.backant.io/')).status).toBe(301);
  process.env.AUTH_URL = 'http://localhost:8787';
  expect(middleware(req('http://localhost:8787/')).headers.get('location')).toBeNull();
});

// Released apps and the current Stripe webhook call the old host's /api/*: those never move.
it('never runs on /api/*', () => {
  const re = new RegExp(`^${config.matcher[0]}$`);
  expect(re.test('/api/license')).toBe(false);
  expect(re.test('/api/stripe/webhook')).toBe(false);
  expect(re.test('/account')).toBe(true);
  expect(re.test('/app/login')).toBe(true);
});
