/**
 * The changelog, from the releases on R2 (never from a code host): the versions under releases/ up to LATEST (the
 * version in latest.json, written only by promote.sh --latest), each with its date, its minimum macOS and its
 * release notes from that version's appcast.xml (Sparkle's single <item>).
 */
import { latest } from './download';

const VERSION = /^\d+\.\d+\.\d+$/;

export type Release = { version: string; build: string | null; date: string | null; minimumSystem: string | null; notes: string[] };

const pick = (xml: string, tag: string) => xml.match(new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`))?.[1]?.trim() ?? null;
const unCdata = (s: string) => s.replace(/^<!\[CDATA\[([\s\S]*)\]\]>$/, '$1');
const decode = (s: string) =>
  s
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&amp;/g, '&');
const text = (html: string) =>
  decode(html.replace(/<\/?(?:b|i|em|strong|a|code|span|small)\b[^>]*>/g, '').replace(/<[^>]+>/g, ' '))
    .replace(/\s+/g, ' ')
    .trim();

/** The notes of a release as plain lines: its list items, else its paragraphs, else its text. Never HTML. */
export function notesOf(description: string | null): string[] {
  if (!description) return [];
  const html = unCdata(description).includes('<') ? unCdata(description) : decode(unCdata(description));
  for (const tag of ['li', 'p']) {
    const items = [...html.matchAll(new RegExp(`<${tag}\\b[^>]*>([\\s\\S]*?)</${tag}>`, 'g'))].map((m) => text(m[1])).filter(Boolean);
    if (items.length) return items;
  }
  const all = text(html);
  return all ? [all] : [];
}

/** One release from its appcast.xml (the first <item>). */
export function parseAppcast(version: string, xml: string): Release {
  const item = xml.match(/<item>([\s\S]*?)<\/item>/)?.[1] ?? '';
  const pub = pick(item, 'pubDate');
  const date = pub && !Number.isNaN(Date.parse(pub)) ? new Date(pub).toISOString() : null;
  return {
    version: pick(item, 'sparkle:shortVersionString') ?? version,
    build: pick(item, 'sparkle:version'),
    date,
    minimumSystem: pick(item, 'sparkle:minimumSystemVersion'),
    notes: notesOf(pick(item, 'description')),
  };
}

const parts = (v: string) => v.split('.').map(Number);
/** Newer first. */
export function compareVersions(a: string, b: string): number {
  const [x, y] = [parts(a), parts(b)];
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return y[i] - x[i];
  return 0;
}

/** The published releases, newest first, up to LATEST; at most `limit`. Empty before the first promotion. */
export async function releasesOf(b: R2Bucket, limit = 30): Promise<Release[]> {
  const top = await latest(b);
  if (!top) return [];
  const versions: string[] = [];
  let cursor: string | undefined;
  do {
    const page = await b.list({ prefix: 'releases/', delimiter: '/', cursor });
    for (const p of page.delimitedPrefixes) {
      const v = p.slice('releases/'.length, -1);
      if (VERSION.test(v) && compareVersions(v, top) >= 0) versions.push(v);
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  versions.sort(compareVersions);
  const out: Release[] = [];
  for (const v of versions.slice(0, limit)) {
    const feed = await b.get(`releases/${v}/appcast.xml`);
    out.push(feed ? parseAppcast(v, await feed.text()) : { version: v, build: null, date: null, minimumSystem: null, notes: [] });
  }
  return out;
}

const day = (iso: string) => new Date(iso).toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC' });
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

/**
 * The release list of /changelog as HTML (worker.ts puts it into the static page's [data-releases]), newest first,
 * the first tagged Latest; before the first release, the line that says one is on its way. Every value is escaped.
 */
export function releasesHtml(list: Release[]): string {
  if (!list.length) return '<div class="s-prose"><p>The first release is on its way. It will be listed here the day it ships.</p></div>';
  const item = (r: Release, i: number) => {
    const meta = [r.date && day(r.date), r.minimumSystem && `macOS ${r.minimumSystem} or later`].filter(Boolean).join(' · ');
    const notes = r.notes.length ? `<ul class="s-release-notes">${r.notes.map((n) => `<li>${esc(n)}</li>`).join('')}</ul>` : '';
    const tag = i === 0 ? '<span class="s-mono s-release-tag">Latest</span>' : '';
    return `<li><h2 class="s-release-title">${esc(r.version)}${tag}</h2><p class="s-mono">${esc(meta)}</p>${notes}</li>`;
  };
  return `<ol class="s-releases">${list.map(item).join('')}</ol>`;
}
