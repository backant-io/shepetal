import { defineCloudflareConfig } from '@opennextjs/cloudflare';
import staticAssetsIncrementalCache from '@opennextjs/cloudflare/overrides/incremental-cache/static-assets-incremental-cache';

// The prerendered pages, robots.txt and the sitemap are served from their build-time copies (the static-assets cache,
// filled by `opennextjs-cloudflare deploy|upload`), answered by OpenNext's routing before the Next server loads: a
// React render per request did not fit the Workers Free plan's 10 ms of CPU. The cache is read-only, so nothing here
// may revalidate (no `revalidate`, revalidatePath/Tag or 'use cache'); that would need another incremental cache.
export default defineCloudflareConfig({ incrementalCache: staticAssetsIncrementalCache, enableCacheInterception: true });
