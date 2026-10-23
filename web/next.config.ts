import type { NextConfig } from 'next';
import { initOpenNextCloudflareForDev } from '@opennextjs/cloudflare';
import { shepetalDomain } from './domain.config.mjs';
import { securityHeaders } from './security-headers.mjs';

// Gives `next dev` the D1 binding from wrangler.toml (local D1 in .wrangler/).
initOpenNextCloudflareForDev();

const nextConfig: NextConfig = {
  // Pin the root: stray lockfiles in parent folders otherwise become the workspace root.
  outputFileTracingRoot: __dirname,
  // The site's one domain (wrangler.toml [vars]), inlined for what is built ahead of time: metadata, OG, the sitemap.
  env: { SHEPETAL_DOMAIN: shepetalDomain() },
  // No experimental.inlineCss: it puts the CSS in the page twice (a <style> and the RSC payload), 49.8 KB gzip
  // against 24.9 KB plus a cacheable stylesheet, and Lighthouse mobile scored one point lower with it.
  async headers() {
    return [{ source: '/:path*', headers: securityHeaders() }];
  },
  // A path no route answers shows the prerendered not-found page (status 404), served from the cache like the other
  // pages (open-next.config.ts). Without this OpenNext asks for /404, which has no prerendered copy, and renders it.
  async rewrites() {
    return { beforeFiles: [], afterFiles: [], fallback: [{ source: '/:path*', destination: '/_not-found' }] };
  },
};

export default nextConfig;
