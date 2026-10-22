import { getCloudflareContext } from '@opennextjs/cloudflare';

/**
 * Email, plain text, from support@shepetal.app. Two ways out:
 * - to OWNER (Pavel's mailbox, where support@shepetal.app forwards): the NOTIFY binding (wrangler.toml [[send_email]]),
 *   Cloudflare Email Routing's sending to a verified address. Free on Workers Free, and it can reach no one else.
 * - to anyone else (a customer): Amazon SES, only when the secrets SES_ACCESS_KEY_ID, SES_SECRET_ACCESS_KEY and
 *   SES_REGION are set (README.md has the setup). Without them sendMail throws: nothing claims a customer was emailed.
 */
export const OWNER = 'pavel@hegler.tech';
const FROM = 'support@shepetal.app';

export const sesEnabled = () => !!(process.env.SES_ACCESS_KEY_ID && process.env.SES_SECRET_ACCESS_KEY && process.env.SES_REGION);

export async function sendMail(to: string, subject: string, text: string): Promise<void> {
  if (to === OWNER) {
    await getCloudflareContext().env.NOTIFY.send({ to, from: { email: FROM, name: 'shepetal' }, subject, text });
    return;
  }
  if (!sesEnabled()) throw new Error('no email to customers: SES is not set up');
  const region = process.env.SES_REGION!;
  const url = `https://email.${region}.amazonaws.com/v2/email/outbound-emails`;
  const body = JSON.stringify({
    FromEmailAddress: `shepetal <${FROM}>`,
    Destination: { ToAddresses: [to] },
    ReplyToAddresses: [FROM],
    Content: { Simple: { Subject: { Data: subject, Charset: 'UTF-8' }, Body: { Text: { Data: text, Charset: 'UTF-8' } } } },
  });
  const headers = await sigv4({
    method: 'POST', url, body, region, service: 'ses', headers: { 'content-type': 'application/json' },
    key: process.env.SES_ACCESS_KEY_ID!, secret: process.env.SES_SECRET_ACCESS_KEY!,
  });
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
  let key: ArrayBuffer = enc(`AWS4${r.secret}`).buffer as ArrayBuffer;
  for (const part of [day, r.region, r.service, 'aws4_request']) key = await hmac(key, part);
  const signature = hex(await hmac(key, ['AWS4-HMAC-SHA256', date, scope, hex(await sha256(request))].join('\n')));
  // host is signed but not sent: fetch sets it from the URL.
  const { host: _, ...send } = headers;
  return { ...send, authorization: `AWS4-HMAC-SHA256 Credential=${r.key}/${scope}, SignedHeaders=${signed}, Signature=${signature}` };
}
