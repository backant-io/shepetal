import { afterEach, describe, expect, it, vi } from 'vitest';

const notify = vi.hoisted(() => ({ send: vi.fn(async (_: unknown) => ({ messageId: 'm1' })) }));
vi.mock('@opennextjs/cloudflare', () => ({ getCloudflareContext: () => ({ env: { NOTIFY: notify } }) }));
const { OWNER, sendMail, sesEnabled, sigv4 } = await import('./mail');

const SES = { SES_ACCESS_KEY_ID: 'AKIDEXAMPLE', SES_SECRET_ACCESS_KEY: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY', SES_REGION: 'eu-central-1' };
afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});

describe('sigv4', () => {
  // AWS's own test vector (aws-sig-v4-test-suite, get-vanilla): a signer that is off by one byte fails here, not in
  // production on the first customer's cancellation.
  it("signs AWS's get-vanilla request exactly as AWS does", async () => {
    const h = await sigv4({
      method: 'GET', url: 'https://example.amazonaws.com/', body: '', region: 'us-east-1', service: 'service',
      key: SES.SES_ACCESS_KEY_ID, secret: SES.SES_SECRET_ACCESS_KEY, now: new Date('2015-08-30T12:36:00Z'),
    });
    expect(h).toEqual({
      'x-amz-date': '20150830T123600Z',
      authorization: 'AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31',
    });
  });
});

describe('sendMail', () => {
  it("sends to Pavel through the NOTIFY binding, whatever SES's state", async () => {
    await sendMail(OWNER, 'cancel: no_account: x@example.com', 'text');
    expect(notify.send).toHaveBeenCalledWith({ to: OWNER, from: { email: 'support@shepetal.app', name: 'shepetal' }, subject: 'cancel: no_account: x@example.com', text: 'text' });
  });

  // Until Pavel sets up SES there is no way to email a customer, and nothing may pretend there is.
  it('refuses a customer address while SES is not set up, and never sends it through the binding', async () => {
    for (const [k] of Object.entries(SES)) vi.stubEnv(k, '');
    expect(sesEnabled()).toBe(false);
    await expect(sendMail('a@example.com', 's', 't')).rejects.toThrow('SES is not set up');
    expect(notify.send).not.toHaveBeenCalled();
  });

  it('sends a customer email through SES v2 in its region, signed, once the three secrets are there', async () => {
    for (const [k, v] of Object.entries(SES)) vi.stubEnv(k, v);
    const fetch = vi.fn(async (_url: string, _init: RequestInit) => new Response('{"MessageId":"x"}'));
    vi.stubGlobal('fetch', fetch);
    await sendMail('a@example.com', 'Your cancellation', 'Received.');
    const [url, init] = fetch.mock.calls[0];
    expect(url).toBe('https://email.eu-central-1.amazonaws.com/v2/email/outbound-emails');
    expect(JSON.parse(init.body as string)).toEqual({
      FromEmailAddress: 'shepetal <support@shepetal.app>',
      Destination: { ToAddresses: ['a@example.com'] },
      ReplyToAddresses: ['support@shepetal.app'],
      Content: { Simple: { Subject: { Data: 'Your cancellation', Charset: 'UTF-8' }, Body: { Text: { Data: 'Received.', Charset: 'UTF-8' } } } },
    });
    expect((init.headers as Record<string, string>).authorization).toMatch(/^AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE\/\d{8}\/eu-central-1\/ses\/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=[0-9a-f]{64}$/);
    fetch.mockResolvedValueOnce(new Response('{"message":"Email address is not verified."}', { status: 400 }));
    await expect(sendMail('a@example.com', 's', 't')).rejects.toThrow('SES 400: {"message":"Email address is not verified."}');
  });
});
