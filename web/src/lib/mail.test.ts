import { afterEach, describe, expect, it, vi } from 'vitest';

const notify = vi.hoisted(() => ({ send: vi.fn(async (_: unknown) => ({ messageId: 'm1' })) }));
vi.mock('@opennextjs/cloudflare', () => ({ getCloudflareContext: () => ({ env: { NOTIFY: notify } }) }));
const { OWNER, sendMail, sesEnabled, sesSend, sesUrl, SesError, sigv4 } = await import('./mail');

const AT = new Date('2015-08-30T12:36:00Z');
const SES = { SES_ACCESS_KEY_ID: 'AKIDEXAMPLE', SES_SECRET_ACCESS_KEY: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY', SES_REGION: 'eu-central-1' };
const sign = (r: Partial<Parameters<typeof sigv4>[0]>) =>
  sigv4({ method: 'GET', url: 'https://example.amazonaws.com/', body: '', region: 'us-east-1', service: 'service', key: SES.SES_ACCESS_KEY_ID, secret: SES.SES_SECRET_ACCESS_KEY, now: AT, ...r });
afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});

describe('sigv4', () => {
  // AWS's own test vectors (aws-sig-v4-test-suite get-vanilla and post-vanilla): a signer that is off by one byte
  // fails here, not in production on the first welcome email.
  it("signs AWS's get-vanilla and post-vanilla requests exactly as AWS does", async () => {
    expect(await sign({})).toEqual({
      'x-amz-date': '20150830T123600Z',
      authorization: 'AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31',
    });
    expect((await sign({ method: 'POST' })).authorization).toMatch(/Signature=5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b$/);
  });

  // The request SES gets (a JSON body, content-type signed, its own path and region), signed by botocore's SigV4Auth
  // with the same key and time: an independent signer agrees on the shape this module really sends.
  it('signs an SES v2 SendEmail request as botocore does', async () => {
    const h = await sign({
      method: 'POST', url: 'https://email.eu-central-1.amazonaws.com/v2/email/outbound-emails', body: '{"FromEmailAddress":"x"}',
      region: 'eu-central-1', service: 'ses', headers: { 'Content-Type': 'application/json' },
    });
    expect(h.authorization).toBe(
      'AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/eu-central-1/ses/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=258aa984199752c14ebb1a4702f3ebaa11b65ab64314a63a9b0912d884499400',
    );
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

describe('sesSend', () => {
  const mail = { from: 'shepetal <hello@shepetal.app>', to: 'a@example.com', subject: 'Welcome to shepetal', text: 'Hi,', html: '<p>Hi,</p>', headers: { 'List-Unsubscribe': '<https://x/u>' } };

  it('sends text, HTML and the extra headers through SES v2 in its region, from the given sender with replies to support@', async () => {
    const fetch = vi.fn(async (_url: string | URL | Request, _init?: RequestInit) => new Response('{"MessageId":"m-1"}'));
    expect(await sesSend(SES, mail, fetch as typeof globalThis.fetch)).toBe('m-1');
    const [url, init] = fetch.mock.calls[0];
    expect(url).toBe('https://email.eu-central-1.amazonaws.com/v2/email/outbound-emails');
    expect(JSON.parse(init!.body as string)).toEqual({
      FromEmailAddress: 'shepetal <hello@shepetal.app>',
      Destination: { ToAddresses: ['a@example.com'] },
      ReplyToAddresses: ['support@shepetal.app'],
      Content: {
        Simple: {
          Subject: { Data: 'Welcome to shepetal', Charset: 'UTF-8' },
          Body: { Text: { Data: 'Hi,', Charset: 'UTF-8' }, Html: { Data: '<p>Hi,</p>', Charset: 'UTF-8' } },
          Headers: [{ Name: 'List-Unsubscribe', Value: '<https://x/u>' }],
        },
      },
    });
    expect((init!.headers as Record<string, string>).authorization).toMatch(
      /^AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE\/\d{8}\/eu-central-1\/ses\/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=[0-9a-f]{64}$/,
    );
  });

  it("carries SES's status on a refusal, and 0 when SES never answered, so the caller can tell retry from give up", async () => {
    const refused = vi.fn(async () => new Response('{"message":"Email address is not verified."}', { status: 400 }));
    await expect(sesSend(SES, mail, refused as unknown as typeof fetch)).rejects.toMatchObject({ status: 400, message: expect.stringContaining('not verified') });
    const down = vi.fn(async () => {
      throw new TypeError('network');
    });
    await expect(sesSend(SES, mail, down as unknown as typeof fetch)).rejects.toBeInstanceOf(SesError);
    await expect(sesSend(SES, mail, down as unknown as typeof fetch)).rejects.toMatchObject({ status: 0 });
  });

  // The trial emails mark an email failed for good only when SES refused that one message (MessageRejected): the type,
  // not the status, tells it from a paused account or a malformed request, which are 400s too.
  it("carries SES's error type, from the x-amzn-ErrorType header or the body", async () => {
    const answer = (init: ResponseInit, body = '{}') => vi.fn(async () => new Response(body, init)) as unknown as typeof fetch;
    await expect(sesSend(SES, mail, answer({ status: 400, headers: { 'x-amzn-ErrorType': 'MessageRejected:http://internal.amazon.com/coral/' } }))).rejects.toMatchObject({ type: 'MessageRejected' });
    await expect(sesSend(SES, mail, answer({ status: 400 }, '{"__type":"com.amazonaws#SendingPausedException"}'))).rejects.toMatchObject({ type: 'SendingPausedException' });
    await expect(sesSend(SES, mail, answer({ status: 503 }, 'not json'))).rejects.toMatchObject({ status: 503, type: '' });
  });

  it('sends nothing without all three secrets', async () => {
    const fetch = vi.fn();
    await expect(sesSend({ ...SES, SES_REGION: '' }, mail, fetch)).rejects.toThrow('SES is not set up');
    expect(fetch).not.toHaveBeenCalled();
  });

  // SES_API_BASE exists for web/e2e's fake SES. Set by mistake in production, it must not send customer email and
  // the signed request to another server.
  it('takes SES_API_BASE only on this machine', () => {
    expect(sesUrl({ ...SES, SES_API_BASE: 'http://127.0.0.1:4010' })).toBe('http://127.0.0.1:4010/v2/email/outbound-emails');
    expect(sesUrl({ ...SES, SES_API_BASE: 'https://evil.example' })).toBe('https://email.eu-central-1.amazonaws.com/v2/email/outbound-emails');
    expect(sesUrl({ ...SES, SES_API_BASE: 'http://127.0.0.1.evil.example' })).toBe('https://email.eu-central-1.amazonaws.com/v2/email/outbound-emails');
  });
});
