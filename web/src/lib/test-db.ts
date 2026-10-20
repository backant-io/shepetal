import { readFileSync } from 'node:fs';
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
    const sql = readFileSync(new URL('../../migrations/0001_init.sql', import.meta.url), 'utf8')
      .replace(/--.*$/gm, '')
      .split(';')
      .filter((s) => s.trim());
    await DB.batch(sql.map((s) => DB.prepare(s)));
  });
  afterAll(() => dispose());
  beforeEach(async () => {
    await DB.batch(['DELETE FROM tokens', 'DELETE FROM device_codes', 'DELETE FROM users'].map((s) => DB.prepare(s)));
  });
}
