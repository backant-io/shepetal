/**
 * The waitlist's switch and words, apart from waitlist.ts so the static pages, the FAQ and the sitemap read them
 * without the database or email code.
 *
 * WAITLIST in wrangler.toml [vars], "off" until Pavel approves. next.config.ts inlines it into the build (the pages
 * and the sitemap), and the Worker reads the same var at runtime (the routes). Off: no form, no page that takes an
 * address, no link to one, and POST /api/waitlist and the confirmation link answer 404 without reading the request.
 * Unsubscribe keeps working either way: it can only remove an address.
 */
export const waitlistOn = (env: { WAITLIST?: string } = { WAITLIST: process.env.WAITLIST }) => env.WAITLIST === 'on';

export const PLATFORMS = { windows: 'Windows', linux: 'Linux', iphone: 'iPhone' } as const;
export type Platform = keyof typeof PLATFORMS;

/** The checkbox's words. The form shows exactly this, and each row stores what it showed. */
export const CONSENT_TEXT = 'Email me when shepetal comes to a platform I chose. You use my email for this only, and I can unsubscribe anytime.';

/** Where each answer goes: static pages, prerendered and served from the cache. */
export const PAGE = {
  thanks: '/waitlist/thanks',
  check: '/waitlist/check',
  confirmed: '/waitlist/confirmed',
  unsubscribe: '/waitlist/unsubscribe',
  unsubscribed: '/waitlist/unsubscribed',
  badLink: '/waitlist/link',
} as const;
