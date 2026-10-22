/**
 * One plain-text email through Amazon SES v2 (SendEmail), with fetch and WebCrypto only: no AWS SDK, which would not
 * fit the Workers Free plan's 10 ms of CPU. From "shepetal <hello@shepetal.app>", Reply-To support@shepetal.app.
 * The secrets SES_ACCESS_KEY_ID and SES_SECRET_ACCESS_KEY, and SES_REGION (eu-central-1), are set in production.
 */
export type SesEnv = { SES_ACCESS_KEY_ID?: string; SES_SECRET_ACCESS_KEY?: string; SES_REGION?: string };
export type Mail = { to: string; subject: string; text: string; headers?: Record<string, string> };

export const FROM = 'shepetal <hello@shepetal.app>';
export const REPLY_TO = 'support@shepetal.app';

/** Throws when SES is not set up or refuses the email. */
export async function sesSend(env: SesEnv, m: Mail, now = new Date()): Promise<void> {
  const { SES_ACCESS_KEY_ID: key, SES_SECRET_ACCESS_KEY: secret } = env;
  if (!key || !secret) throw new Error('SES is not set up');
  const region = env.SES_REGION || 'eu-central-1';
  const url = `https://email.${region}.amazonaws.com/v2/email/outbound-emails`;
  const body = JSON.stringify({
    FromEmailAddress: FROM,
    Destination: { ToAddresses: [m.to] },
    ReplyToAddresses: [REPLY_TO],
    Content: {
      Simple: {
        Subject: { Data: m.subject, Charset: 'UTF-8' },
        Body: { Text: { Data: m.text, Charset: 'UTF-8' } },
        ...(m.headers && { Headers: Object.entries(m.headers).map(([Name, Value]) => ({ Name, Value })) }),
      },
    },
  });
  const headers = await sigv4({ method: 'POST', url, body, region, service: 'ses', key, secret, now, headers: { 'content-type': 'application/json' } });
  const res = await fetch(url, { method: 'POST', headers, body });
  if (!res.ok) throw new Error(`SES ${res.status}: ${(await res.text()).slice(0, 300)}`);
}

const enc = (s: string) => new TextEncoder().encode(s);
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, '0')).join('');
const sha256 = (s: string) => crypto.subtle.digest('SHA-256', enc(s));
async function hmac(key: BufferSource, s: string): Promise<ArrayBuffer> {
  const k = await crypto.subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return crypto.subtle.sign('HMAC', k, enc(s));
}

/**
 * AWS Signature Version 4 for a request with no query string: the headers to send (x-amz-date, authorization and the
 * given ones). host is signed but left to fetch. docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
 */
export async function sigv4(r: {
  method: string; url: string; body: string; region: string; service: string; key: string; secret: string; now: Date;
  headers?: Record<string, string>;
}): Promise<Record<string, string>> {
  const u = new URL(r.url);
  const date = r.now.toISOString().replace(/[-:]|\.\d{3}/g, ''); // 20150830T123600Z
  const day = date.slice(0, 8);
  const headers: Record<string, string> = { host: u.host, 'x-amz-date': date };
  for (const [k, v] of Object.entries(r.headers ?? {})) headers[k.toLowerCase()] = v.trim();
  const names = Object.keys(headers).sort();
  const signed = names.join(';');
  const canonical = [r.method, u.pathname, '', ...names.map((n) => `${n}:${headers[n]}`), '', signed, hex(await sha256(r.body))].join('\n');
  const scope = `${day}/${r.region}/${r.service}/aws4_request`;
  let k: ArrayBuffer = enc(`AWS4${r.secret}`).buffer as ArrayBuffer;
  for (const part of [day, r.region, r.service, 'aws4_request']) k = await hmac(k, part);
  const signature = hex(await hmac(k, ['AWS4-HMAC-SHA256', date, scope, hex(await sha256(canonical))].join('\n')));
  const { host: _, ...send } = headers;
  return { ...send, authorization: `AWS4-HMAC-SHA256 Credential=${r.key}/${scope}, SignedHeaders=${signed}, Signature=${signature}` };
}
