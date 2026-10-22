// The landing page's scroll story: the ONE table of every scroll timing and writing window.
// A port of the approved design's build.mjs (board 5, "full scroll story"), with the same numbers. Do not re-tune.
//
// add(selector, keyframes, track, from, to, range = 'contain', fill = 'both'). Progress is 0..1 of the track's
// pin ('contain') or of it sliding in from below ('entry'). Several entries on one selector become animation lists
// (used with fill 'none' for the docked key, which presses once per writing window).
// Native: named view timelines (hoisted with timeline-scope) + animation-range.
// Fallback (no scroll timelines): StoryMotion writes --pN / --eN on the root and --p on each track; the paused
// animations are scrubbed by their delay.
// Dictated text: each FLOW sentence is one span per word, written in its window with a caret that follows it.
//
// scripts/story-css.mjs writes storyCss() to story.generated.css, and choreography.test.ts keeps the two equal.
// This file must stay plain erasable TypeScript with no imports, so that node runs the script without a build step.

export type Track = 't0' | 't1' | 't2' | 't3' | 't4' | 't5';
type Range = 'contain' | 'entry';
type Fill = 'both' | 'none';
type Entry = { k: string; t: Track; a: number; b: number; range: Range; fill: Fill };

/** How far each pinned chapter scrolls, on top of its own screen: max(37.5rem, 100vh) + this. */
export const TRACK_LENGTH: Record<Track, string> = {
  t0: '130vh',
  t1: '125vh',
  t2: '100vh',
  t3: '120vh',
  t4: '115vh',
  t5: '55vh',
};

/**
 * A sentence the page writes word by word: its track, the window it is written in (from, to), and when its caret
 * shows (caretFrom before the first word, caretTo after the last; -1 and 9 mean never and always).
 */
export type Flow = { track: Track; from: number; to: number; caretFrom: number; caretTo: number; text: string };

export const FLOWS = {
  // 1 · Every app
  f0: {
    track: 't1',
    from: 0.06,
    to: 0.2,
    caretFrom: -1,
    caretTo: 0.22,
    text: 'Hi Maja, can you send me the address for Saturday?',
  },
  f1: {
    track: 't1',
    from: 0.24,
    to: 0.38,
    caretFrom: 0.22,
    caretTo: 0.4,
    text: 'Running ten minutes late, start without me.',
  },
  f2: {
    track: 't1',
    from: 0.42,
    to: 0.56,
    caretFrom: 0.4,
    caretTo: 0.58,
    text: 'Retry once before showing the error.',
  },
  f3: {
    track: 't1',
    from: 0.6,
    to: 0.74,
    caretFrom: 0.58,
    caretTo: 0.76,
    text: 'Fix the date picker on small screens"',
  },
  f4: { track: 't1', from: 0.78, to: 0.92, caretFrom: 0.76, caretTo: 9, text: 'Plans for the spring garden' },
  // 3 · Private
  b3: {
    track: 't3',
    from: 0.48,
    to: 0.9,
    caretFrom: 0.44,
    caretTo: 9,
    text: 'Note to self: ask the doctor about the new prescription.',
  },
  // 4 · Meetings
  t0: {
    track: 't4',
    from: 0.3,
    to: 0.47,
    caretFrom: 0.27,
    caretTo: 0.5,
    text: 'Can we push the launch review to Thursday?',
  },
  t1: {
    track: 't4',
    from: 0.53,
    to: 0.7,
    caretFrom: 0.5,
    caretTo: 0.73,
    text: 'Thursday works, I’ll bring the numbers.',
  },
  t2: {
    track: 't4',
    from: 0.76,
    to: 0.93,
    caretFrom: 0.73,
    caretTo: 9,
    text: 'Great, then we lock the plan on Friday.',
  },
} as const satisfies Record<string, Flow>;
export type FlowId = keyof typeof FLOWS;

/** The words of a sentence, as the page splits them. */
export const flowWords = (id: FlowId): string[] => FLOWS[id].text.trim().split(/\s+/);

/** The hero's six words, written by the held key. */
export const HERO_WORDS = ['Your', 'words', 'appear', 'wherever', 'you', 'speak.'] as const;

/** The typed lane of chapter 2, one word at a time. */
export const TYPED_WORDS = ['I’ll', 'send', 'the', 'revised', 'contract', 'before', 'lunch', 'tomorrow.'] as const;

const r3 = (v: number) => +(+v).toFixed(4);

type Table = { anim: Map<string, Entry[]>; carets: [string, number, number][]; write: [Track, number, number][] };

/** Every animation, caret and writing window of the page, in the order build.mjs adds them. */
export function table(): Table {
  const anim = new Map<string, Entry[]>();
  const carets: [string, number, number][] = [];
  const write: [Track, number, number][] = [];
  const add = (
    sel: string,
    k: string,
    t: Track,
    a: number,
    b: number,
    range: Range = 'contain',
    fill: Fill = 'both',
  ) => {
    if (!anim.has(sel)) anim.set(sel, []);
    anim.get(sel)!.push({ k, t, a: r3(a), b: r3(b), range, fill });
  };

  // 0 · hero: press 4-12%, words 16-65%, release 70-78%, then the key shrinks into the corner 80-98%
  const W = (i: number) => [0.16 + i * 0.07, 0.31 + i * 0.07] as const;
  for (const [s, k] of [
    ['.kc-k-cap', 'kc-press'],
    ['.kc-ks-r', 'kc-shR'],
    ['.kc-ks-d', 'kc-shD'],
    ['.kc-k-led', 'kc-led'],
    ['.kc-k-glow', 'kc-glow'],
  ])
    add(s, k, 't0', 0, 1);
  for (const i of [0, 1, 2, 3, 4, 5])
    for (const k of ['wx', 'wy', 'wi', 'wo']) add(`.kc-w${i} .kc-${k}`, `kc-${k}`, 't0', ...W(i));
  const land = [0, 1, 2, 3, 4, 5].map((i) => r3(W(i)[0] + 0.9 * (W(i)[1] - W(i)[0])));
  land.forEach((l, i) => carets.push([`kc-w${i}`, l, land[i + 1] ?? 9]));
  // the trial button shows only once the last word has landed, before the key lets go
  add('.kc-ctarow', 'kc-cta', 't0', 0.66, 0.7);
  add('.kc-stagekey', 'kc-out', 't0', 0.8, 0.802);
  add('.kc-dock-in', 'kc-dockin', 't0', 0.8, 0.98);
  add('.kc-dock-out', 'kc-dockout', 't5', 0, 0.5, 'entry');
  add('.kc-shf', 'kc-hold-shh', 't0', 0.03, 0.79, 'contain', 'none');

  // 2 · speed: spoken lands whole at 24-27%, typed crawls word by word to 87% (about 4x as long, key not held)
  add('.kc-sp-led', 'kc-speak', 't2', 0.06, 0.24);
  add('.kc-sp-text', 'kc-in', 't2', 0.24, 0.27);
  carets.push(['kc-c2s', -1, 0.24], ['kc-c2e', 0.26, 9]);
  const T2 = [0, 1, 2, 3, 4, 5, 6, 7].map((j) => r3(0.06 + j * 0.115));
  T2.forEach((t, j) => {
    add(`.kc-ty${j}`, 'kc-pop', 't2', t, t + 0.006);
    carets.push([`kc-ty${j}`, t + 0.006, T2[j + 1] ?? 9]);
  });
  carets.push(['kc-c2t', -1, T2[0]]);
  write.push(['t2', 0.04, 0.27]);
  // 3 · private: the line to the network is cut, "Offline" appears, only then are the words written into the box
  add('.kc-net-l', 'kc-out', 't3', 0.06, 0.22);
  add('.kc-net-b', 'kc-cut', 't3', 0.06, 0.32);
  add('.kc-net-a', 'kc-shrink', 't3', 0.12, 0.36);
  add('.kc-off', 'kc-in', 't3', 0.34, 0.42);
  // 4 · meetings: the reminder arrives, Record is pressed, then the transcript (speaker labels pop with their line)
  add('.kc-rem', 'kc-slide', 't4', 0.04, 0.16);
  add('.kc-recface', 'kc-btn', 't4', 0.2, 0.26);
  add('.kc-rec-a', 'kc-out', 't4', 0.22, 0.25);
  add('.kc-rec-b', 'kc-pop', 't4', 0.22, 0.25);
  [0, 1, 2].forEach((k) => add(`.kc-sl${k}`, 'kc-pop', 't4', 0.3 + k * 0.23, 0.31 + k * 0.23));
  // 5 · the name
  add('.kc-n0', 'kc-in', 't5', 0.05, 0.3);
  add('.kc-n1', 'kc-in', 't5', 0.12, 0.45);
  add('.kc-n2', 'kc-in', 't5', 0.3, 0.6);

  // the dictated sentences, in page order: one step per word, the caret riding the last written word
  for (const id of Object.keys(FLOWS) as FlowId[]) {
    const { track: t, from: a, to: b, caretFrom: C0, caretTo: C1 } = FLOWS[id];
    const n = flowWords(id).length,
      step = (b - a) / n,
      dur = Math.min(0.025, step * 0.8);
    const ts = Array.from({ length: n }, (_, j) => r3(a + step * j));
    ts.forEach((tj, j) => {
      add(`.kc-${id}-${j}`, 'kc-flow', t, tj, tj + dur);
      carets.push([`kc-${id}-${j}`, tj + dur * 0.5, j < n - 1 ? ts[j + 1] + dur * 0.5 : C1]);
    });
    carets.push([`kc-${id}-s`, C0, ts[0] + dur * 0.5]);
    write.push([t, a - 0.015, b + 0.01]);
  }

  // the docked key and the recording mark: pressed once per writing window, released in between
  for (const [t, a, b] of write.sort((x, y) => x[0].localeCompare(y[0]) || x[1] - y[1]))
    for (const [s, k] of [
      ['.kd-k-cap', 'kc-hold'],
      ['.kd-k-led', 'kc-hold-led'],
      ['.kd-ks-r', 'kc-hold-shR'],
      ['.kd-ks-d', 'kc-hold-shD'],
      ['.kc-dock-on', 'kc-hold-on'],
      ['.kc-shf', 'kc-hold-shh'],
    ])
      add(s, k, t, a, b, 'contain', 'none');

  return { anim, carets, write };
}

const pct = (v: number) => r3(v * 100) + '%';
const list = (es: Entry[], f: (e: Entry) => string) => es.map(f).join(', ');

/** The scroll CSS: the native scroll-timeline path, the paused-animation fallback, the caret windows and the track lengths. */
export function storyCss(): string {
  const { anim, carets } = table();
  let css = '@supports (animation-timeline: view()) {\n';
  for (const [sel, es] of anim)
    css += `  .kc ${sel} { animation-name: ${list(es, (e) => e.k)}; animation-duration: auto; animation-timing-function: linear; animation-fill-mode: ${list(es, (e) => e.fill)}; animation-timeline: ${list(es, (e) => '--' + e.t)}; animation-range: ${list(es, (e) => `${e.range} ${pct(e.a)} ${e.range} ${pct(e.b)}`)}; }\n`;
  css += '}\n@supports not (animation-timeline: view()) {\n';
  for (const [sel, es] of anim)
    css += `  .kc ${sel} { animation-name: ${list(es, (e) => e.k)}; animation-duration: 1s; animation-timing-function: linear; animation-fill-mode: ${list(es, (e) => e.fill)}; animation-play-state: paused; animation-delay: ${list(es, (e) => `calc((var(--${e.range === 'entry' ? 'e' : 'p'}${e.t.slice(1)}) - ${e.a}) / ${r3(e.b - e.a)} * -1s)`)}; }\n`;
  css += '}\n';
  for (const [c, l, n] of carets) css += `.${c} { --l: ${r3(l)}; --n: ${r3(n)}; }\n`;
  for (const [t, len] of Object.entries(TRACK_LENGTH))
    css += `.kc-${t} { height: calc(max(37.5rem, 100vh) + ${len}); }\n`;
  return css;
}
