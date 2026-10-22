/**
 * PostHog's project key and host. The key is a Worker secret (POSTHOG_KEY, set at GO; empty means analytics are off),
 * the host is in wrangler.toml [vars] (POSTHOG_HOST, backant's project on the US cloud). No imports, so worker.ts can
 * use it too.
 */
export function analyticsConfig(env: { POSTHOG_KEY?: string; POSTHOG_HOST?: string } = process.env as Record<string, string | undefined>): { key: string; host: string } {
  return { key: (env.POSTHOG_KEY ?? '').trim(), host: (env.POSTHOG_HOST || 'https://us.i.posthog.com').replace(/\/+$/, '') };
}
