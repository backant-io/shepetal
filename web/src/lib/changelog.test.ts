import { describe, expect, it } from 'vitest';
import { compareVersions, notesOf, parseAppcast, releasesHtml, releasesOf } from './changelog';

const feed = (v: string, b: number, date: string, notes = '') =>
  `<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><title>${v}</title><pubDate>${date}</pubDate><sparkle:version>${b}</sparkle:version><sparkle:shortVersionString>${v}</sparkle:shortVersionString><sparkle:minimumSystemVersion>14.4</sparkle:minimumSystemVersion>${notes}<enclosure url="https://shepetal.app/download/${v}/Shepetal-${v}.dmg" length="1"/></item></channel></rss>`;

/** A bucket on a Map, with R2's list(prefix, delimiter). */
function bucket(files: Record<string, string>) {
  const m = new Map(Object.entries(files));
  return {
    get: async (k: string) => (m.has(k) ? { text: async () => m.get(k)!, json: async () => JSON.parse(m.get(k)!) } : null),
    list: async ({ prefix, delimiter }: { prefix: string; delimiter: string }) => {
      const set = new Set<string>();
      for (const k of m.keys()) if (k.startsWith(prefix)) set.add(prefix + k.slice(prefix.length).split(delimiter)[0] + delimiter);
      return { objects: [], delimitedPrefixes: [...set], truncated: false };
    },
  } as unknown as R2Bucket;
}

describe('changelog', () => {
  it('reads a Sparkle item: version, build, date, minimum macOS and its notes as plain lines', () => {
    const r = parseAppcast('0.2.0', feed('0.2.0', 745, 'Tue, 20 Oct 2026 10:00:00 +0000', '<description><![CDATA[<ul><li>Faster <b>startup</b>.</li><li>Fixes &amp; more.</li></ul>]]></description>'));
    expect(r).toEqual({ version: '0.2.0', build: '745', date: '2026-10-20T10:00:00.000Z', minimumSystem: '14.4', notes: ['Faster startup.', 'Fixes & more.'] });
  });

  it('never passes HTML through, and reads paragraphs or plain text too', () => {
    expect(notesOf('<![CDATA[<p>One.</p><p><script>x</script>Two.</p>]]>')).toEqual(['One.', 'x Two.']);
    expect(notesOf('&lt;p&gt;Escaped.&lt;/p&gt;')).toEqual(['Escaped.']);
    expect(notesOf(null)).toEqual([]);
  });

  it('lists the published versions newest first, up to LATEST, never staging or a newer unannounced one', async () => {
    const b = bucket({
      'latest.json': '{"version":"0.10.0","build":900}',
      'releases/0.9.1/appcast.xml': feed('0.9.1', 800, 'Mon, 19 Oct 2026 10:00:00 +0000'),
      'releases/0.10.0/appcast.xml': feed('0.10.0', 900, 'Wed, 21 Oct 2026 10:00:00 +0000'),
      'releases/0.11.0/appcast.xml': feed('0.11.0', 950, 'Thu, 22 Oct 2026 10:00:00 +0000'),
      'releases/0.2.0/Shepetal-0.2.0.dmg': 'x',
      'staging/0.12.0/appcast.xml': feed('0.12.0', 999, 'Thu, 22 Oct 2026 10:00:00 +0000'),
    });
    expect((await releasesOf(b)).map((r) => r.version)).toEqual(['0.10.0', '0.9.1', '0.2.0']);
    expect(await releasesOf(bucket({}))).toEqual([]);
  });

  it('orders versions as numbers', () => {
    expect(['0.9.0', '0.10.0', '1.0.0', '0.9.10'].sort(compareVersions)).toEqual(['1.0.0', '0.10.0', '0.9.10', '0.9.0']);
  });
});

describe('the release list on /changelog', () => {
  it('says the first release is on its way before there is one', () => {
    expect(releasesHtml([])).toBe('<div class="s-prose"><p>The first release is on its way. It will be listed here the day it ships.</p></div>');
  });

  it('lists the releases newest first, the first tagged Latest, with date, minimum macOS and notes', () => {
    const html = releasesHtml([
      { version: '0.2.0', build: '2', date: '2026-10-20T10:00:00.000Z', minimumSystem: '14.4', notes: ['Faster startup.'] },
      { version: '0.1.0', build: '1', date: null, minimumSystem: null, notes: [] },
    ]);
    expect(html).toBe(
      '<ol class="s-releases"><li><h2 class="s-release-title">0.2.0<span class="s-mono s-release-tag">Latest</span></h2><p class="s-mono">October 20, 2026 · macOS 14.4 or later</p><ul class="s-release-notes"><li>Faster startup.</li></ul></li>' +
        '<li><h2 class="s-release-title">0.1.0</h2><p class="s-mono"></p></li></ol>',
    );
  });

  // The notes are plain text from R2 (notesOf), put into the page as HTML: every value is escaped.
  it('escapes every value', () => {
    const x = '"><img src=x onerror=1>';
    const html = releasesHtml([{ version: x, build: null, date: null, minimumSystem: x, notes: [x, '<script>alert(1)</script> & co'] }]);
    expect(html).not.toMatch(/<img|<script/);
    expect(html).toContain('&#34;&#62;&#60;img src=x onerror=1&#62;');
    expect(html).toContain('&#60;script&#62;alert(1)&#60;/script&#62; &#38; co');
  });
});
