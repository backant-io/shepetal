// The security headers, from one place: next.config.ts puts them on everything Next answers, worker.ts on what it
// answers itself (/api/license, /api/app/token, /api/app/revoke, /api/cancel). The CSP has no nonce, so prerendered pages are
// served as they were built.

/** The headers for every answer. Analytics run on the server (src/lib/server-analytics.ts): pages connect to the site only. */
export function securityHeaders() {
  return [
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
}
