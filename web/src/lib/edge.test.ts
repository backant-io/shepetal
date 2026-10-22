import { afterEach, describe, expect, it, vi } from 'vitest';
import { securityHeaders } from '../../security-headers.mjs';
import { withEdgeHtml } from './edge-html';

// What worker.ts adds at the edge. The pages are served from their build-time copies without Next (open-next.config.ts),
// so whatever depends on the request has to be added here, and only here.

/** The Workers HTMLRewriter (absent in Node), reduced to what withEdgeHtml uses: each handler sees one element. */
function fakeRewriter(done: string[]) {
  return class {
    on(selector: string, h: { element: (e: unknown) => void }) {
      h.element({
        append: (html: string) => done.push(`${selector} + ${html}`),
        setAttribute: (k: string, v: string) => done.push(`${selector} ${k}=${v}`),
      });
      return this;
    }
    transform(res: Response) {
      return new Response(res.body, res);
    }
  };
}

const page = (etag = '"abc"') => new Response('<html><head></head></html>', { headers: { 'content-type': 'text/html; charset=utf-8', etag } });

describe('withEdgeHtml', () => {
  afterEach(() => vi.unstubAllGlobals());
  const run = (url: string, env: { POSTHOG_KEY?: string; POSTHOG_HOST?: string }, res = page()) => {
    const done: string[] = [];
    vi.stubGlobal('HTMLRewriter', fakeRewriter(done));
    return { out: withEdgeHtml(res, env, new URL(url)), done };
  };

  it('adds the refresh that starts the download on /install, carrying ?ref= and utm_* to it and the link, with analytics off too', () => {
    const { out, done } = run('https://shepetal.app/install?ref=producthunt&utm_source=x.com&other=1', {});
    expect(done).toEqual([
      'head + <meta http-equiv="refresh" content="1;url=/download?ref=producthunt&utm_source=x.com">',
      'a[href="/download"] href=/download?ref=producthunt&utm_source=x.com',
    ]);
    expect(out.headers.get('etag')).toBeNull();
    // Without attribution the download still starts.
    expect(run('https://shepetal.app/install', {}).done).toEqual(['head + <meta http-equiv="refresh" content="1;url=/download">']);
  });

  it('adds the analytics meta to every HTML page when the key is set, and drops the ETag of the page as built', () => {
    const { out, done } = run('https://shepetal.app/faq', { POSTHOG_KEY: 'phc_x', POSTHOG_HOST: 'https://us.i.posthog.com' });
    expect(done).toEqual(['head + <meta name="shepetal-analytics" content="{&quot;key&quot;:&quot;phc_x&quot;,&quot;host&quot;:&quot;https://us.i.posthog.com&quot;}">']);
    expect(out.headers.get('etag')).toBeNull();
  });

  // The unsubscribe page is static; the link's signed token reaches its form only here.
  it('puts the signed ?t= into the unsubscribe form on /waitlist/unsubscribe, and nothing that is not a signed token', () => {
    const t = `${'a'.repeat(20)}.${'B'.repeat(43)}`;
    const { out, done } = run(`https://shepetal.app/waitlist/unsubscribe?t=${t}`, {});
    expect(done).toEqual([`input[name="t"] value=${t}`]);
    expect(out.headers.get('etag')).toBeNull();
    for (const bad of ['%22%3E%3Cscript%3E', `${t}x`, 'abc', '']) {
      const res = page();
      expect(run(`https://shepetal.app/waitlist/unsubscribe?t=${bad}`, {}, res).out, bad).toBe(res);
    }
    const res = page();
    expect(run(`https://shepetal.app/faq?t=${t}`, {}, res).out).toBe(res);
  });

  it('leaves the page as built without a key and without attribution, and never touches what is not HTML', () => {
    for (const url of ['https://shepetal.app/', 'https://shepetal.app/faq?ref=x']) {
      const res = page();
      expect(run(url, {}, res).out).toBe(res);
    }
    const json = Response.json({});
    expect(run('https://shepetal.app/install?ref=x', { POSTHOG_KEY: 'phc_x' }, json).out).toBe(json);
  });
});

describe('securityHeaders: one list for Next (next.config.ts) and for what worker.ts answers itself', () => {
  const h = Object.fromEntries(securityHeaders('https://us.i.posthog.com/').map(({ key, value }) => [key, value]));

  it('keeps every header the site promises', () => {
    expect(h['Strict-Transport-Security']).toBe('max-age=31536000; includeSubDomains; preload');
    expect(h['X-Frame-Options']).toBe('DENY');
    expect(h['X-Content-Type-Options']).toBe('nosniff');
    expect(h['Referrer-Policy']).toBe('strict-origin-when-cross-origin');
    expect(h['Permissions-Policy']).toBe('camera=(), microphone=(), geolocation=()');
  });

  it('lets forms post only to the site, Google, Stripe Checkout and the app; fonts and connections stay on known hosts', () => {
    const csp = h['Content-Security-Policy'];
    expect(csp).toContain("form-action 'self' https://accounts.google.com https://checkout.stripe.com shepetal: http://127.0.0.1:*");
    expect(csp).toContain("font-src 'self' data:");
    expect(csp).toContain("connect-src 'self' https://us.i.posthog.com;");
    expect(csp).toContain("frame-ancestors 'none'");
    expect(csp).toContain("object-src 'none'");
  });
});
