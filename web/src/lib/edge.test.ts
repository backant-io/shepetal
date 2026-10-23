import { afterEach, describe, expect, it, vi } from 'vitest';
import { securityHeaders } from '../../security-headers.mjs';
import { downloadStarter, withEdgeHtml } from './edge-html';

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
  const run = (url: string, res = page()) => {
    const done: string[] = [];
    vi.stubGlobal('HTMLRewriter', fakeRewriter(done));
    return { out: withEdgeHtml(res, new URL(url)), done };
  };

  it('adds the script that starts the download on /install, carrying ?ref= and utm_* to it and the link', () => {
    const { out, done } = run('https://shepetal.app/install?ref=producthunt&utm_source=x.com&other=1');
    expect(done).toEqual([
      'head + <script>addEventListener("DOMContentLoaded",function(){setTimeout(function(){location.replace("/download?ref=producthunt&utm_source=x.com")},1000)})</script>',
      'a[href="/download"] href=/download?ref=producthunt&utm_source=x.com',
    ]);
    // One download starter, the script: no timed meta refresh (axe meta-refresh, Lighthouse accessibility).
    expect(done.filter((d) => d.includes('location.replace'))).toHaveLength(1);
    expect(done.join('\n')).not.toMatch(/http-equiv/i);
    expect(out.headers.get('etag')).toBeNull();
    // Without attribution the download still starts.
    expect(run('https://shepetal.app/install').done).toEqual([`head + ${downloadStarter('')}`]);
    expect(downloadStarter('')).toContain('location.replace("/download")');
  });

  // The unsubscribe page is static; the link's signed token reaches its form only here.
  it('puts the signed ?t= into the unsubscribe form on /waitlist/unsubscribe, and nothing that is not a signed token', () => {
    const t = `${'a'.repeat(20)}.${'B'.repeat(43)}`;
    const { out, done } = run(`https://shepetal.app/waitlist/unsubscribe?t=${t}`);
    expect(done).toEqual([`input[name="t"] value=${t}`]);
    expect(out.headers.get('etag')).toBeNull();
    for (const bad of ['%22%3E%3Cscript%3E', `${t}x`, 'abc', '']) {
      const res = page();
      expect(run(`https://shepetal.app/waitlist/unsubscribe?t=${bad}`, res).out, bad).toBe(res);
    }
    const res = page();
    expect(run(`https://shepetal.app/faq?t=${t}`, res).out).toBe(res);
  });

  it('leaves every other page as built, ETag included (page views are counted on the server, no meta, no script), and never touches what is not HTML', () => {
    for (const url of ['https://shepetal.app/', 'https://shepetal.app/faq?ref=x']) {
      const res = page();
      const { out, done } = run(url, res);
      expect(out).toBe(res);
      expect(done).toEqual([]);
    }
    const json = Response.json({});
    expect(run('https://shepetal.app/install?ref=x', json).out).toBe(json);
  });
});

describe('securityHeaders: one list for Next (next.config.ts) and for what worker.ts answers itself', () => {
  const h = Object.fromEntries(securityHeaders().map(({ key, value }) => [key, value]));

  it('keeps every header the site promises', () => {
    expect(h['Strict-Transport-Security']).toBe('max-age=31536000; includeSubDomains; preload');
    expect(h['X-Frame-Options']).toBe('DENY');
    expect(h['X-Content-Type-Options']).toBe('nosniff');
    expect(h['Referrer-Policy']).toBe('strict-origin-when-cross-origin');
    expect(h['Permissions-Policy']).toBe('camera=(), microphone=(), geolocation=()');
  });

  it('lets forms post only to the site, Google, Stripe Checkout and the app; fonts and connections stay on the site (analytics run on the server)', () => {
    const csp = h['Content-Security-Policy'];
    expect(csp).toContain("form-action 'self' https://accounts.google.com https://checkout.stripe.com shepetal: http://127.0.0.1:*");
    expect(csp).toContain("font-src 'self' data:");
    expect(csp).toContain("connect-src 'self';");
    expect(csp).not.toContain('posthog');
    expect(csp).toContain("frame-ancestors 'none'");
    expect(csp).toContain("object-src 'none'");
  });

  it("allows the inline script that starts the download on /install (edge-html.ts)", () => {
    expect(h['Content-Security-Policy']).toMatch(/script-src 'self' 'unsafe-inline'/);
  });
});
