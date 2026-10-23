// What analytics read from a User-Agent: whether it is a bot or a link preview, the device type and the OS family.
// Nothing else of it is kept or sent. One regular expression each, so it costs microseconds. No imports: worker.ts
// uses it on every page.

// Crawlers, link previews (iMessage sends facebookexternalhit, Slack Slackbot, X Twitterbot) and HTTP libraries.
// Small on purpose: a missed bot is one extra view, a long list is CPU on every request.
const BOT = /bot|crawl|spider|slurp|preview|facebookexternalhit|embedly|whatsapp|telegram|discord|mastodon|pinterest|headless|lighthouse|curl|wget|python|go-http|java\/|okhttp|axios|node-fetch|undici|^node$/i;

/** A crawler, a link preview or a script, or no user agent at all. */
export const isBot = (ua: string | null): boolean => !ua || BOT.test(ua);

/** mobile, tablet or desktop (PostHog's $device_type values). An iPad that asks for the desktop site is a desktop. */
export function deviceType(ua: string): 'Mobile' | 'Tablet' | 'Desktop' {
  if (/iPad|Tablet|Android(?!.*Mobile)/i.test(ua)) return 'Tablet';
  return /Mobi|iPhone|iPod|Android/i.test(ua) ? 'Mobile' : 'Desktop';
}

/** The OS family only, never its version (PostHog's $os values). */
export function osFamily(ua: string): string {
  if (/iPhone|iPad|iPod/.test(ua)) return 'iOS';
  if (/Android/.test(ua)) return 'Android';
  if (/Mac OS X|Macintosh/.test(ua)) return 'Mac OS X';
  if (/Windows/.test(ua)) return 'Windows';
  if (/CrOS/.test(ua)) return 'Chrome OS';
  if (/Linux/.test(ua)) return 'Linux';
  return 'Other';
}
