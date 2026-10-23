import { readdirSync, readFileSync } from 'node:fs';
import { afterAll, beforeAll, beforeEach } from 'vitest';
import { getPlatformProxy } from 'wrangler';

// Tests only. In a test file:
//   vi.mock('./db', () => import('./test-db'));
//   useTestDb();
// and db() is then an in-memory local D1 (the real D1 engine, via wrangler) with migrations/ applied.

let DB: D1Database;
export const db = () => DB;

export function useTestDb() {
  let dispose: () => Promise<void>;
  beforeAll(async () => {
    const proxy = await getPlatformProxy<CloudflareEnv>({ persist: false });
    ({ DB } = proxy.env);
    dispose = proxy.dispose;
    const dir = new URL('../../migrations/', import.meta.url);
    const sql = readdirSync(dir)
      .filter((f) => f.endsWith('.sql'))
      .sort()
      .flatMap((f) => readFileSync(new URL(f, dir), 'utf8').replace(/--.*$/gm, '').split(';'))
      .filter((s) => s.trim());
    await DB.batch(sql.map((s) => DB.prepare(s)));
  });
  afterAll(() => dispose());
  beforeEach(async () => {
    await DB.batch(['DELETE FROM lifecycle_emails', 'DELETE FROM email_unsubscribes', 'DELETE FROM tokens', 'DELETE FROM app_codes', 'DELETE FROM users', 'DELETE FROM stripe_events', 'DELETE FROM visitor_salts', 'DELETE FROM cancellations'].map((s) => DB.prepare(s)));
  });
}
