import { readFileSync } from 'node:fs';
import type { NextConfig } from 'next';
import { initOpenNextCloudflareForDev } from '@opennextjs/cloudflare';
import { wranglerDomain } from './src/lib/wrangler-domain';

// Gives `next dev` the D1 binding from wrangler.toml (local D1 in .wrangler/).
initOpenNextCloudflareForDev();

const securityHeaders = [
  { key: 'X-Frame-Options', value: 'DENY' },
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  { key: 'Strict-Transport-Security', value: 'max-age=31536000; includeSubDomains; preload' },
  { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=()' },
  {
    key: 'Content-Security-Policy',
    value: [
      "default-src 'self'",
      "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: https: blob:",
      // The brand fonts are self-hosted (src/brand/fonts).
      "font-src 'self' data:",
      "connect-src 'self'",
      "frame-src 'self'",
      "frame-ancestors 'none'",
      // shepetal: and the loopback: where the /app/login consent form redirects with the code.
      "form-action 'self' https://accounts.google.com https://checkout.stripe.com shepetal: http://127.0.0.1:*",
      "base-uri 'self'",
      "object-src 'none'",
    ].join('; '),
  },
];

const nextConfig: NextConfig = {
  // Build-time copy of the domain for metadata (metadataBase, OG, canonical); the Worker reads the same var at runtime.
  env: { SHEPETAL_DOMAIN: wranglerDomain(readFileSync(`${__dirname}/wrangler.toml`, 'utf8')) },
  // Pin the root: stray lockfiles in parent folders otherwise become the workspace root.
  outputFileTracingRoot: __dirname,
  // No experimental.inlineCss: it puts the CSS in the page twice (a <style> and the RSC payload), 49.8 KB gzip
  // against 24.9 KB plus a cacheable stylesheet, and Lighthouse mobile scored one point lower with it.
  async headers() {
    return [{ source: '/:path*', headers: securityHeaders }];
  },
};

export default nextConfig;
