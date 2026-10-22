// The visitor salt: a random value per UTC day, in D1 (visitor_salts, migrations/0007), never in the code or a secret.
// The first isolate to need a day's salt makes it; every other one reads the same row. Each isolate keeps the day's
// HMAC key in memory, so a request reads D1 at most once a day, and the id itself is one HMAC. Salts older than
// yesterday are deleted in the same round trip, so none lives longer than 48 h.

const hex = (b: Uint8Array) => [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
export const utcDay = (ms: number) => new Date(ms).toISOString().slice(0, 10);

let cached: { day: string; key: Promise<CryptoKey> } | null = null;

/** The HMAC key for the UTC day of `now`, from memory or (once a day per isolate) from D1. */
export function dailyKey(db: D1Database, now = Date.now()): Promise<CryptoKey> {
  const day = utcDay(now);
  if (cached?.day === day) return cached.key;
  const key = load(db, day, utcDay(now - 86_400_000));
  cached = { day, key };
  // A failed read is not kept: the next request tries again.
  key.catch(() => cached?.key === key && (cached = null));
  return key;
}

async function load(db: D1Database, day: string, yesterday: string): Promise<CryptoKey> {
  const fresh = hex(crypto.getRandomValues(new Uint8Array(32)));
  // One transaction: the first writer wins, everyone reads the winner, and what is older than yesterday goes.
  const [, row] = await db.batch<{ salt: string }>([
    db.prepare('INSERT OR IGNORE INTO visitor_salts (day, salt) VALUES (?, ?)').bind(day, fresh),
    db.prepare('SELECT salt FROM visitor_salts WHERE day = ?').bind(day),
    db.prepare('DELETE FROM visitor_salts WHERE day < ?').bind(yesterday),
  ]);
  const salt = row.results[0]?.salt;
  if (!salt) throw new Error('visitor salt: no row');
  return crypto.subtle.importKey('raw', new TextEncoder().encode(salt), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
}

/** Tests only: forget the key this isolate holds. */
export const forgetDailyKey = () => void (cached = null);
