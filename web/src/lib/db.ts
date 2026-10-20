import { getCloudflareContext } from '@opennextjs/cloudflare';

/** shepetal's own D1 database (binding DB in wrangler.toml). Call inside a request. */
export const db = () => getCloudflareContext().env.DB;
