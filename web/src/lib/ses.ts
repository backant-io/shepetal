/**
 * Email to customers through Amazon SES v2 (SendEmail), signed with SigV4 on WebCrypto: no SDK, so a cron run stays
 * far inside the Workers Free plan's 10 ms of CPU. The secrets SES_ACCESS_KEY_ID, SES_SECRET_ACCESS_KEY and SES_REGION
 * (eu-central-1) are Worker secrets. sigv4 has the same shape as the one in legal/eu-consumer's mail.ts: once both are
 * merged, one of them goes.
 */
export const FROM = 'shepetal <hello@shepetal.app>';
export const REPLY_TO = 'support@shepetal.app';

export type SesEnv = {
  SES_ACCESS_KEY_ID?: string;
  SES_SECRET_ACCESS_KEY?: string;
  SES_REGION?: string;
  /** web/e2e only: a fake SES on this machine. Ignored unless it is http://127.0.0.1 or http://localhost. */
  SES_API_BASE?: string;
};

export type Mail = { to: string; subject: string; text: string; html: string; headers?: Record<string, string> };

/** SES did not take the email. `status` is SES's HTTP status, 0 when no answer came. */
export class SesError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

export const sesConfigured = (env: SesEnv) => !!(env.SES_ACCESS_KEY_ID && env.SES_SECRET_ACCESS_KEY && env.SES_REGION);

/** The SendEmail URL: SES in SES_REGION, or the e2e's fake on this machine. */
export function sesUrl(env: SesEnv): string {
  const fake = env.SES_API_BASE ? new URL(env.SES_API_BASE) : null;
  const local = fake && fake.protocol === 'http:' && (fake.hostname === '127.0.0.1' || fake.hostname === 'localhost');
  return `${local ? fake.origin : `https://email.${env.SES_REGION}.amazonaws.com`}/v2/email/outbound-emails`;
}

/** Sends one email and returns SES's MessageId. Throws SesError when SES refuses it or does not answer. */
export async function sendMail(env: SesEnv, mail: Mail, fetchImpl: typeof fetch = fetch): Promise<string> {
  if (!sesConfigured(env)) throw new SesError(0, 'SES is not set up');
  const url = sesUrl(env);
  const body = JSON.stringify({
    FromEmailAddress: FROM,
    Destination: { ToAddresses: [mail.to] },
    ReplyToAddresses: [REPLY_TO],
    Content: {
      Simple: {
        Subject: { Data: mail.subject, Charset: 'UTF-8' },
        Body: { Text: { Data: mail.text, Charset: 'UTF-8' }, Html: { Data: mail.html, Charset: 'UTF-8' } },
        Headers: Object.entries(mail.headers ?? {}).map(([Name, Value]) => ({ Name, Value })),
      },
    },
  });
  const headers = await sigv4({
    method: 'POST', url, body, region: env.SES_REGION!, service: 'ses', headers: { 'content-type': 'application/json' },
    key: env.SES_ACCESS_KEY_ID!, secret: env.SES_SECRET_ACCESS_KEY!,
  });
  let res: Response;
  try {
    res = await fetchImpl(url, { method: 'POST', headers, body, signal: AbortSignal.timeout(5000) });
  } catch (e) {
    throw new SesError(0, `SES did not answer: ${(e as Error).message}`);
  }
  const text = await res.text();
  if (!res.ok) throw new SesError(res.status, `SES ${res.status}: ${text.slice(0, 300)}`);
  return (JSON.parse(text) as { MessageId?: string }).MessageId ?? '';
}

const enc = (s: string) => new TextEncoder().encode(s);
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, '0')).join('');
const sha256 = (s: string) => crypto.subtle.digest('SHA-256', enc(s));
const hmacKey = (key: BufferSource) => crypto.subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
async function hmac(key: BufferSource, s: string): Promise<ArrayBuffer> {
  return crypto.subtle.sign('HMAC', await hmacKey(key), enc(s));
}

// The signing key changes once a day: derived once (four HMACs and five key imports), not for every email.
const signingKeys = new Map<string, Promise<CryptoKey>>();
function signingKey(secret: string, day: string, region: string, service: string): Promise<CryptoKey> {
  const id = [secret, day, region, service].join('\n');
  let k = signingKeys.get(id);
  if (!k) {
    if (signingKeys.size > 8) signingKeys.clear();
    k = (async () => {
      let key: ArrayBuffer = enc(`AWS4${secret}`).buffer as ArrayBuffer;
      for (const part of [day, region, service, 'aws4_request']) key = await hmac(key, part);
      return hmacKey(key);
    })();
    signingKeys.set(id, k);
  }
  return k;
}

/**
 * AWS Signature Version 4 for a request without a query string, with WebCrypto only: the headers to send, x-amz-date
 * and the authorization; host is signed but left to fetch
 * (docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html).
 */
export async function sigv4(r: {
  method: string; url: string; body: string; region: string; service: string; key: string; secret: string;
  headers?: Record<string, string>; now?: Date;
}): Promise<Record<string, string>> {
  const u = new URL(r.url);
  const date = (r.now ?? new Date()).toISOString().replace(/[-:]|\.\d{3}/g, ''); // 20150830T123600Z
  const day = date.slice(0, 8);
  const headers: Record<string, string> = { host: u.host, 'x-amz-date': date };
  for (const [k, v] of Object.entries(r.headers ?? {})) headers[k.toLowerCase()] = v.trim();
  const names = Object.keys(headers).sort();
  const signed = names.join(';');
  const request = [r.method, u.pathname, '', ...names.map((n) => `${n}:${headers[n]}`), '', signed, hex(await sha256(r.body))].join('\n');
  const scope = `${day}/${r.region}/${r.service}/aws4_request`;
  const key = await signingKey(r.secret, day, r.region, r.service);
  const signature = hex(await crypto.subtle.sign('HMAC', key, enc(['AWS4-HMAC-SHA256', date, scope, hex(await sha256(request))].join('\n'))));
  // host is signed but not sent: fetch sets it from the URL.
  const { host: _, ...send } = headers;
  return { ...send, authorization: `AWS4-HMAC-SHA256 Credential=${r.key}/${scope}, SignedHeaders=${signed}, Signature=${signature}` };
}
