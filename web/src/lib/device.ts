import { db } from './db';
import { createToken, randomSecret, sha256 } from './tokens';

// Device login (RFC 8628 style), see API.md: the app calls start, the user approves
// the user_code on /device, and the app polls token until it gets an access token.
export const EXPIRES_IN = 600; // seconds a device code lives
export const INTERVAL = 5; // seconds the app must wait between polls

// No vowels, so a code never spells a word; no 0/O or 1/I to misread.
const ALPHABET = 'BCDFGHJKLMNPQRSTVWXZ';

export type PollError = 'authorization_pending' | 'slow_down' | 'expired_token' | 'access_denied';
export type PollResult = { error: PollError } | { access_token: string; email: string };

const iso = (ms: number) => new Date(ms).toISOString();

/** "bcdf-ghjk", "BCDFGHJK" and "bcdf ghjk" are all the code BCDF-GHJK. */
export function normalizeUserCode(code: string): string {
  const c = code.toUpperCase().replace(/[^A-Z]/g, '');
  return `${c.slice(0, 4)}-${c.slice(4)}`;
}

/** POST /api/device/start. `base` is the site origin the user opens to approve. */
export async function startDevice(base: string, now = Date.now()) {
  const device_code = randomSecret();
  const user_code = normalizeUserCode(
    [...crypto.getRandomValues(new Uint8Array(8))].map((b) => ALPHABET[b % ALPHABET.length]).join(''),
  );
  await db().batch([
    db().prepare('DELETE FROM device_codes WHERE expires_at <= ?1').bind(iso(now)),
    db()
      .prepare('INSERT INTO device_codes (device_code_hash, user_code, expires_at) VALUES (?1, ?2, ?3)')
      .bind(await sha256(device_code), user_code, iso(now + EXPIRES_IN * 1000)),
  ]);
  return {
    device_code,
    user_code,
    verification_uri_complete: `${base}/device?code=${user_code}`,
    expires_in: EXPIRES_IN,
    interval: INTERVAL,
  };
}

/**
 * The signed-in user (`email`, an existing users row) approves or denies `userCode` on /device.
 * False if the code is unknown, expired or already decided.
 */
export async function approveDevice(userCode: string, email: string, approve: boolean, now = Date.now()) {
  const r = await db()
    .prepare(
      "UPDATE device_codes SET status = ?2, email = ?3 WHERE user_code = ?1 AND status = 'pending' AND expires_at > ?4",
    )
    .bind(normalizeUserCode(userCode), approve ? 'approved' : 'denied', email, iso(now))
    .run();
  return r.meta.changes === 1;
}

/** POST /api/device/token. An approved code yields exactly one access token. */
export async function pollDevice(deviceCode: string, now = Date.now()): Promise<PollResult> {
  const hash = await sha256(deviceCode);
  const row = await db()
    .prepare('SELECT status, email, expires_at, last_polled_at FROM device_codes WHERE device_code_hash = ?1')
    .bind(hash)
    .first<{ status: string; email: string | null; expires_at: string; last_polled_at: string | null }>();
  if (!row || Date.parse(row.expires_at) <= now) return { error: 'expired_token' };

  await db().prepare('UPDATE device_codes SET last_polled_at = ?2 WHERE device_code_hash = ?1').bind(hash, iso(now)).run();
  if (row.last_polled_at && now - Date.parse(row.last_polled_at) < INTERVAL * 1000) return { error: 'slow_down' };
  if (row.status === 'pending') return { error: 'authorization_pending' };
  if (row.status === 'denied') return { error: 'access_denied' };
  if (row.status !== 'approved' || !row.email) return { error: 'expired_token' }; // consumed

  // Consume, then mint: of two concurrent polls only one wins the conditional update.
  const consumed = await db()
    .prepare("UPDATE device_codes SET status = 'consumed' WHERE device_code_hash = ?1 AND status = 'approved'")
    .bind(hash)
    .run();
  if (consumed.meta.changes !== 1) return { error: 'expired_token' };
  return { access_token: await createToken(row.email), email: row.email };
}
