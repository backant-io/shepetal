import { describe, expect, it } from 'vitest';
import { compareVersions, notesOf, parseAppcast, releasesOf } from './changelog';

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
