'use client';

import { useEffect } from 'react';

/**
 * Page views for backant's PostHog project (US cloud), cookieless: memory persistence (no cookie, no storage), no
 * autocapture, no session recording, no surveys or feature flags, every event tagged app=shepetal. It runs only when
 * the Worker put the project key on the page (<meta name="shepetal-analytics">, worker.ts, when POSTHOG_KEY is set),
 * and never for a browser that sends Do Not Track or Global Privacy Control. The library loads after the page is idle.
 */
export function Analytics() {
  useEffect(() => {
    const meta = document.querySelector<HTMLMetaElement>('meta[name="shepetal-analytics"]');
    if (!meta?.content) return;
    const nav = navigator as Navigator & { globalPrivacyControl?: boolean };
    if (nav.doNotTrack === '1' || nav.globalPrivacyControl) return;
    let cfg: { key?: string; host?: string };
    try {
      cfg = JSON.parse(meta.content);
    } catch {
      return;
    }
    if (!cfg.key || !cfg.host) return;
    const start = async () => {
      const { posthog } = await import('posthog-js/dist/module.slim.no-external');
      posthog.init(cfg.key!, {
        api_host: cfg.host,
        persistence: 'memory',
        autocapture: false,
        capture_pageview: false,
        capture_pageleave: false,
        disable_session_recording: true,
        disable_surveys: true,
        advanced_disable_flags: true,
        capture_dead_clicks: false,
        capture_heatmaps: false,
        capture_performance: false,
        disable_external_dependency_loading: true,
        respect_dnt: true,
        person_profiles: 'never',
        // tag first, then the page view, so no event leaves without app=shepetal
        loaded: (ph) => {
          ph.register({ app: 'shepetal', $geoip_disable: true });
          ph.capture('$pageview');
        },
      });
    };
    const idle = (window as Window & { requestIdleCallback?: (cb: () => void, o?: { timeout: number }) => number }).requestIdleCallback;
    if (idle) idle(() => void start(), { timeout: 4000 });
    else setTimeout(() => void start(), 2000);
  }, []);
  return null;
}
