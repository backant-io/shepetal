import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import { track } from './analytics';
import { appcast, download, file, latest, releaseRoute } from './download';

vi.mock('./analytics', async (actual) => ({ ...(await actual<typeof import('./analytics')>()), track: vi.fn(async () => {}) }));

// The release bucket as R2 behaves for what download.ts asks: get/head by key, a range only as {offset, length} inside
// the object (R2 throws otherwise). It records every key read, so a test can prove staging/ is never touched.
function bucket(objects: Record<string, string | Uint8Array>) {
  const read: string[] = [];
  const bytes = (k: string) => (typeof objects[k] === 'string' ? new TextEncoder().encode(objects[k] as string) : (objects[k] as Uint8Array));
  const meta = (k: string) => ({
    size: bytes(k).length,
    httpEtag: `"etag-${k}"`,
    writeHttpMetadata: (h: Headers) => h.set('content-type', k.endsWith('.dmg') ? 'application/x-apple-diskimage' : 'text/plain'),
  });
  const r2 = {
    read,
    async head(k: string) {
      read.push(k);
      return k in objects ? meta(k) : null;
    },
    async get(k: string, o?: { range?: { offset: number; length: number } }) {
      read.push(k);
      if (!(k in objects)) return null;
      const all = bytes(k);
      const { offset = 0, length = all.length } = o?.range ?? {};
      if (Object.keys(o?.range ?? {}).some((x) => x !== 'offset' && x !== 'length') || offset < 0 || length <= 0 || offset + length > all.length) {
        throw new Error(`R2: the requested range is not satisfiable: ${JSON.stringify(o?.range)}`);
      }
      const body = all.slice(offset, offset + length);
      return { ...meta(k), body: new Response(body).body, json: async () => JSON.parse(new TextDecoder().decode(all)) };
    },
  };
  return r2 as typeof r2 & R2Bucket;
}

const DMG = Uint8Array.from({ length: 100 }, (_, i) => i);
const FEED = '<?xml version="1.0" standalone="yes"?>\n<rss version="2.0"><channel><item><title>0.2.0</title></item></channel></rss>\n';
const released = (extra: Record<string, string> = {}) =>
  bucket({
    'releases/0.2.0/Shepetal-0.2.0.dmg': DMG,
    'releases/0.2.0/Shepetal-0.2.0.dmg.sha256': 'abc  Shepetal-0.2.0.dmg\n',
    'releases/0.2.0/appcast.xml': FEED,
    // Built and staged by CI, not promoted: never served, whatever latest.json says.
    'staging/0.3.0/Shepetal-0.3.0.dmg': 'unreviewed',
    'staging/0.3.0/appcast.xml': '<rss><channel><item>unreviewed</item></channel></rss>',
    ...extra,
  });
const get = (range?: string) => new Request('https://example.test/x', { headers: range ? { range } : {} });

describe('LATEST is latest.json in R2, and /download and /appcast.xml both follow it', () => {
  it('before the first promotion: /download is the coming-soon page and the feed is empty, neither cached', async () => {
    const b = released();
    const page = await download(b);
    expect(page.status).toBe(200);
    expect(await page.text()).toContain('shepetal for Mac is coming soon');
    expect(page.headers.get('cache-control')).toBe('no-cache');
    const feed = await appcast(b, get());
    const xml = await feed.text();
    expect(feed.status).toBe(200);
    expect(feed.headers.get('content-type')).toBe('application/xml; charset=utf-8');
    expect(feed.headers.get('cache-control')).toBe('no-cache');
    // Sparkle needs valid RSS with its namespace; no <item> means "no update", not an error.
    expect(xml).toMatch(/^<\?xml [^>]*\?>\n<rss version="2\.0" xmlns:sparkle="http:\/\/www\.andymatuschak\.org\/xml-namespaces\/sparkle"><channel\/><\/rss>\n$/);
  });

  it('LATEST 0.2.0: /download 302s to its DMG on this site, and the feed is the promoted appcast byte for byte', async () => {
    const b = released({ 'latest.json': '{"version":"0.2.0","build":745}' });
    const res = await download(b);
    expect(res.status).toBe(302);
    // Relative: the Worker knows no domain, so a domain move changes nothing here.
    expect(res.headers.get('location')).toBe('/download/0.2.0/Shepetal-0.2.0.dmg');
    expect(res.headers.get('cache-control')).toBe('public, max-age=300');
    const feed = await appcast(b, get());
    expect(feed.status).toBe(200);
    expect(await feed.text()).toBe(FEED);
    expect(feed.headers.get('content-type')).toBe('application/xml; charset=utf-8');
    expect(feed.headers.get('cache-control')).toBe('public, max-age=300');
    expect(b.read.filter((k) => k.startsWith('staging/'))).toEqual([]);
  });

  it('a latest.json that names a path or a short version is a 500, and nothing in staging/ is ever read', async () => {
    for (const bad of ['{"version":"../staging/0.3.0"}', '{"version":"0.2"}', '{"version":"0.3.0/../../staging/0.3.0"}', '{}', 'not json']) {
      const b = released({ 'latest.json': bad });
      await expect(latest(b), bad).rejects.toThrow();
      await expect(download(b), bad).rejects.toThrow();
      await expect(appcast(b, get()), bad).rejects.toThrow();
      expect(b.read.filter((k) => k.startsWith('staging/')), bad).toEqual([]);
    }
  });
});

describe('/download/<version>/<file> serves promoted files only, and resumes', () => {
  const dmg = (b: R2Bucket, range?: string) => file(b, get(range), '0.2.0', 'Shepetal-0.2.0.dmg');
  const body = async (r: Response) => new Uint8Array(await r.arrayBuffer());

  it('a whole download is 200 with every byte, cached for a year as immutable, and says it takes ranges', async () => {
    const res = await dmg(released());
    expect(res.status).toBe(200);
    expect(await body(res)).toEqual(DMG);
    expect(res.headers.get('cache-control')).toBe('public, max-age=31536000, immutable');
    expect(res.headers.get('accept-ranges')).toBe('bytes');
    expect(res.headers.get('etag')).toBe('"etag-releases/0.2.0/Shepetal-0.2.0.dmg"');
    expect(res.headers.get('content-type')).toBe('application/x-apple-diskimage');
    expect(res.headers.get('content-range')).toBeNull();
    // So a browser shows the size and the progress of a 20 MB download.
    expect(res.headers.get('content-length')).toBe('100');
  });

  it('a Range request is 206 with exactly those bytes and their content-range (closed, open and suffix forms)', async () => {
    for (const [range, from, to] of [
      ['bytes=0-9', 0, 9],
      ['bytes=90-', 90, 99], // what curl -C - and a browser resume send
      ['bytes=-5', 95, 99],
      ['bytes=95-1000', 95, 99], // past the end: clamped
      ['bytes=-1000', 0, 99],
    ] as const) {
      const res = await dmg(released(), range);
      expect(res.status, range).toBe(206);
      expect(res.headers.get('content-range'), range).toBe(`bytes ${from}-${to}/100`);
      expect(res.headers.get('content-length'), range).toBe(String(to - from + 1));
      expect(await body(res), range).toEqual(DMG.slice(from, to + 1));
      expect(res.headers.get('cache-control'), range).toBe('public, max-age=31536000, immutable');
    }
  });

  it('a range past the end is 416 with the size; a range it cannot read as one bytes range is served whole', async () => {
    for (const range of ['bytes=100-', 'bytes=100-200', 'bytes=-0']) {
      const res = await dmg(released(), range);
      expect(res.status, range).toBe(416);
      expect(res.headers.get('content-range'), range).toBe('bytes */100');
    }
    for (const range of ['bytes=0-1,5-6', 'bytes=9-0', 'bytes=-', 'items=0-9', 'bytes=x-9']) {
      const res = await dmg(released(), range);
      expect(res.status, range).toBe(200);
      expect(await body(res), range).toEqual(DMG);
    }
  });

  it('is 404 for a bad version, a file outside the release, latest.json, staging/ and an unpromoted version', async () => {
    const b = released({ 'latest.json': '{"version":"0.2.0"}' });
    for (const [v, f] of [
      ['0.2', 'Shepetal-0.2.dmg'],
      ['..', 'latest.json'],
      ['0.2.0', 'latest.json'],
      ['0.2.0', 'notes.txt'],
      ['0.2.0', 'Shepetal-0.3.0.dmg'],
      ['0.3.0', 'Shepetal-0.3.0.dmg'], // only in staging/
      ['9.9.9', 'appcast.xml'],
    ]) {
      const res = await file(b, get(), v, f);
      expect(res.status, `${v}/${f}`).toBe(404);
    }
    expect((await file(b, get('bytes=0-9'), '9.9.9', 'Shepetal-9.9.9.dmg')).status).toBe(404);
    expect(b.read.filter((k) => k.startsWith('staging/') || k === 'releases/0.2.0/latest.json')).toEqual([]);
    // The sha256 and the appcast of a promoted version are served too (promote.sh smoke-tests an unlisted feed).
    expect(await (await file(b, get(), '0.2.0', 'Shepetal-0.2.0.dmg.sha256')).text()).toBe('abc  Shepetal-0.2.0.dmg\n');
    expect(await (await file(b, get(), '0.2.0', 'appcast.xml')).text()).toBe(FEED);
  });
});

describe('releaseRoute: the release paths worker.ts serves before Next', () => {
  // Through OpenNext a 22 MB DMG ran out of the Free plan's 10 ms of CPU and ended early (error 1102), so worker.ts
  // serves exactly these paths from R2 itself and must hand everything else on to Next.
  const at = (path: string, method = 'GET') => new Request(`https://shepetal.app${path}`, { method });
  const LATEST = { 'latest.json': '{"version":"0.2.0","build":745}' };

  it('serves /download, the release files and /appcast.xml from R2', async () => {
    const b = released(LATEST);
    expect((await releaseRoute(b, at('/download?ref=x')))?.headers.get('location')).toBe('/download/0.2.0/Shepetal-0.2.0.dmg');
    expect(new Uint8Array(await (await releaseRoute(b, at('/download/0.2.0/Shepetal-0.2.0.dmg')))!.arrayBuffer())).toEqual(DMG);
    expect(await (await releaseRoute(b, at('/appcast.xml')))!.text()).toBe(FEED);
    expect((await releaseRoute(b, at('/download/0.2.0/Shepetal-0.2.0.dmg', 'HEAD')))?.status).toBe(200);
  });

  it('hands every other path and method on to Next', async () => {
    const b = released(LATEST);
    for (const path of ['/', '/install', '/downloads', '/download/0.2.0', '/download/0.2.0/x/y', '/api/license', '/appcast.xml/x']) {
      expect(await releaseRoute(b, at(path))).toBeNull();
    }
    expect(await releaseRoute(b, at('/download', 'POST'))).toBeNull();
  });
});

describe('download_served counts downloads people start (B1)', () => {
  const LATEST = { 'latest.json': '{"version":"0.2.0","build":745}' };
  const counted = () => vi.mocked(track).mock.calls.filter(([e]) => e === 'download_served');
  const dl = (method: string, ua: string) =>
    new Request('https://shepetal.app/download?ref=x', { method, headers: { 'user-agent': ua } });

  it('a browser GET counts once; a HEAD, a crawler, a link preview (Slack, iMessage, X) or a script downloads nothing and is not counted, but still gets its answer', async () => {
    vi.mocked(track).mockClear();
    const b = released(LATEST);
    const chrome = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
    expect((await releaseRoute(b, dl('GET', chrome)))?.status).toBe(302);
    expect(counted()).toHaveLength(1);
    expect(counted()[0][2]).toMatchObject({ version: '0.2.0', ref: 'x' });
    for (const [method, ua] of [
      ['HEAD', chrome],
      ['GET', 'Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)'],
      ['GET', 'facebookexternalhit/1.1 Facebot Twitterbot/1.0'],
      ['GET', 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)'],
      ['GET', 'curl/8.4.0'],
      ['GET', ''],
    ]) {
      expect((await releaseRoute(b, dl(method, ua)))?.status, `${method} ${ua}`).toBe(302);
    }
    expect(counted()).toHaveLength(1);
  });
});

describe('Pavel, 22.10.26', () => {
  const SRC = join(__dirname, '..');
  it('Download is open: /download never asks to sign in (sign-in happens in the app)', () => {
    const route = readFileSync(join(SRC, 'app', 'download', 'route.ts'), 'utf8');
    expect(route).not.toMatch(/@\/lib\/auth|auth\(|signin/);
  });

  it('nothing public points at the code host: no source file of the site names it (releases come from R2)', () => {
    const sources = readdirSync(SRC, { recursive: true, encoding: 'utf8' }).filter((f) => /\.tsx?$/.test(f));
    expect(sources.length).toBeGreaterThan(20);
    // [h]: so this file does not match itself.
    const named = sources.filter((f) => /git[h]ub/i.test(readFileSync(join(SRC, f), 'utf8')));
    expect(named).toEqual([]);
  });
});
