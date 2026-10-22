// The site's own sealed cookies (the web session, the Google sign-in in progress, the app consent): AES-256-GCM with a
// key derived from AUTH_SECRET by HKDF, and the cookie's name as additional data, so a value sealed for one cookie is
// never valid in another. Encrypted, not only signed: the session holds the email, the OAuth cookie the PKCE verifier.
// No imports, so the e2e scripts (Node) can mint cookies with it.

const enc = new TextEncoder();
/** Bumping it ends every session without touching AUTH_SECRET, which is also the analytics salt and never rotates. */
const INFO = 'shepetal cookie v1';
let cached: { secret: string; key: Promise<CryptoKey> } | undefined;

function keyOf(secret: string): Promise<CryptoKey> {
  if (!secret) throw new Error('AUTH_SECRET is not set');
  if (cached?.secret !== secret) {
    const key = crypto.subtle
      .importKey('raw', enc.encode(secret), 'HKDF', false, ['deriveKey'])
      .then((ikm) =>
        crypto.subtle.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(), info: enc.encode(INFO) }, ikm, { name: 'AES-GCM', length: 256 }, false, [
          'encrypt',
          'decrypt',
        ]),
      );
    cached = { secret, key };
  }
  return cached.key;
}

export const b64url = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
export const unb64url = (s: string) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));

/** `data` sealed for the cookie `name`, valid for maxAgeS seconds: base64url(iv || ciphertext). */
export async function seal(secret: string, name: string, data: Record<string, unknown>, maxAgeS: number, now = Date.now()): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const plain = enc.encode(JSON.stringify({ ...data, exp: now + maxAgeS * 1000 }));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: enc.encode(name) }, await keyOf(secret), plain));
  const out = new Uint8Array(iv.length + ct.length);
  out.set(iv);
  out.set(ct, iv.length);
  return b64url(out);
}

/** What seal() put in `value` for the cookie `name`, or null: tampered, sealed for another cookie or key, or expired. */
export async function unseal(secret: string, name: string, value: string, now = Date.now()): Promise<Record<string, unknown> | null> {
  const key = await keyOf(secret); // outside the try: a missing AUTH_SECRET fails loud
  try {
    const raw = unb64url(value);
    if (raw.length < 12 + 16) return null;
    const plain = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: raw.subarray(0, 12), additionalData: enc.encode(name) }, key, raw.subarray(12));
    const data = JSON.parse(new TextDecoder().decode(plain));
    return data && typeof data.exp === 'number' && data.exp > now ? data : null;
  } catch {
    return null;
  }
}

/** Equal strings, compared in constant time for equal lengths (the OAuth state, the CSRF value). */
export function same(a: string, b: string): boolean {
  const x = enc.encode(a);
  const y = enc.encode(b);
  if (x.length !== y.length) return false;
  let d = 0;
  for (let i = 0; i < x.length; i++) d |= x[i] ^ y[i];
  return d === 0;
}
