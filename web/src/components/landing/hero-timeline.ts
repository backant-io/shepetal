/**
 * The hero demo's timeline: one key goes down, a line is spoken, the key comes up and the line lands, in a mail,
 * a chat and a note. All times are ms from the first paint. plan() does the arithmetic on the server and
 * HERO_JS, the inline script, only turns its times into WAAPI animations.
 */

export type App = 'mail' | 'chat' | 'note';

/** What is said in each app. The text that lands is the same words: shepetal writes what you say. */
export const SCENES: { app: App; said: string }[] = [
  { app: 'mail', said: 'Can you send me the address?' },
  { app: 'chat', said: 'Running ten minutes late, start without me.' },
  { app: 'note', said: 'Pack the boots, the maps and the good coffee.' },
];

// Speech rhythm: a word takes 150 ms plus 36 ms a letter, and a comma or full stop adds a 200 ms breath.
const WORD_BASE = 150;
const PER_LETTER = 36;
const BREATH = 200;
const FIRST_WORD = 150; // the first word starts this long after the key goes down
// The brand's word reveal (identity.md, motion): 240 ms a word, 40 ms apart, a line done in 560 ms or less.
export const WORD_MS = 240;
export const STAGGER = 40;
export const REVEAL_MAX = 560;
// The app pastes the text as the key comes up (FnGesture); 100 ms is the paste.
export const WRITE_DELAY = 100;
const FIRST_DOWN = 600; // the first press, once the window has settled at 380
const WRITING_MIN = 600; // the blue ring shows at least this long, so Writing reads as a state and not a glitch
const LEAVE = 120; // the ring and the pill leave
const READ = 1600; // from the landed line to the next app
const SWAP = 440; // the window leaves (200), the next one enters from 120 and has settled at 440
const BEAT = 400; // from a settled window to the next press

const letters = (w: string) => w.replace(/[^\p{L}\p{N}]/gu, '').length;
const say = (w: string) => WORD_BASE + PER_LETTER * letters(w);

/** When each word starts, the first one at `at`, and when the key comes up after the last one. */
export function onsets(words: string[], at = 0): { said: number[]; up: number } {
  const said = [at];
  for (const w of words.slice(0, -1)) said.push(said[said.length - 1] + say(w) + (/[,.]$/.test(w) ? BREATH : 0));
  return { said, up: said[said.length - 1] + say(words[words.length - 1]) };
}

export type Scene = {
  /** When this scene's animations are made: the end of the scene before. */
  from: number;
  /** When they have all finished. */
  to: number;
  /** When the previous app's window leaves (from the second scene). */
  swap?: number;
  down: number;
  said: number[];
  up: number;
  /** When each word starts to land in the window. */
  land: number[];
  landEnd: number;
  /** When the ring and the pill start to leave. */
  out: number;
};

/** The whole pass: one scene for each app, back to back. */
export function plan(): Scene[] {
  const scenes: Scene[] = [];
  let from = 0;
  let down = FIRST_DOWN;
  let swap: number | undefined;
  for (const { said: line } of SCENES) {
    const words = line.split(' ');
    const { said, up } = onsets(words, down + FIRST_WORD);
    const land = words.map((_, i) => up + WRITE_DELAY + i * STAGGER);
    const landEnd = land[land.length - 1] + WORD_MS;
    const out = Math.max(up + WRITING_MIN, landEnd);
    scenes.push({ from, to: out + LEAVE, ...(swap === undefined ? {} : { swap }), down, said, up, land, landEnd, out });
    from = out + LEAVE;
    swap = landEnd + READ;
    down = swap + SWAP + BEAT;
  }
  return scenes;
}

/**
 * The browser half, called with plan(). A plain string, so no compiled function is ever stringified.
 * It makes about 30 animations a scene, all with fill 'both', so a scene not yet played shows its rest
 * frame; the next scene is made when they have all finished, and the pass stops on the finished note.
 * It changes no DOM attributes, so React hydrates the server HTML as it is. Reduced motion: it returns
 * at once and the finished frame stays.
 */
export const HERO_JS = `function (P) {
  var s = document.getElementById('hero-stage'), d = document;
  if (!s || !s.animate || matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  var q = function (c, r) { return (r || s).querySelectorAll(c); },
    W = q('.hd-win'), L = q('.hd-line'), K = q('.hd-key')[0], E = q('.hd-key i')[0], R = q('.hd-rec')[0], B = q('.hd-write')[0],
    Pi = q('.hd-pill')[0], Lr = q('.hd-pill-rec')[0], Lw = q('.hd-pill-write')[0],
    SE = 'cubic-bezier(.2,0,0,1)', LE = 'cubic-bezier(.4,0,1,1)', BR = 'cubic-bezier(.42,0,.58,1)', N = 'none',
    all = [], cur = [], vis = false, gen = 0;
  function op(o, t) { return t == null ? { opacity: o } : { opacity: o, transform: t }; }
  /* one animation through [time, style, easing to the next] steps, timed from the scene's start o */
  function a(el, o, f) {
    var t0 = f[0][0], n = f[f.length - 1][0] - t0;
    var x = el.animate(f.map(function (k) { return Object.assign({ offset: (k[0] - t0) / n, easing: k[2] || 'linear' }, k[1]); }),
      { delay: t0 - o, duration: n, fill: 'both' });
    cur.push(x); all.push(x);
  }
  function scene(i) {
    var p = P[i], o = p.from, w = W[i], c = q('.hd-caret', w);
    cur = [];
    if (i) {
      a(W[i - 1], o, [[p.swap, op(1, N), LE], [p.swap + 200, op(0, 'translateY(-8px)')]]);
      a(w, o, [[p.swap + 120, op(0, 'translateY(10px) scale(.985)'), SE], [p.swap + 440, op(1, N)]]);
    }
    /* the carets switch in 1 ms: two keyframes at the same end offset can leave the compositor on the first one */
    a(c[0], o, [[o, op(1)], [p.up, op(1)], [p.up + 1, op(0)]]);
    a(c[1], o, [[o, op(0)], [p.landEnd, op(0)], [p.landEnd + 1, op(1)]]);
    q('.hd-word', w).forEach(function (e, j) { var t = p.land[j]; a(e, o, [[t, op(0, 'translateY(.25em)'), SE], [t + 240, op(1, N)]]); });
    q('span', L[i]).forEach(function (e, j) {
      var t = p.said[j], h = p.land[j];
      a(e, o, [[t, op(0, N), SE], [t + 120, op(1, N)], [h, op(1, N), LE], [h + 200, op(0, 'translateY(-6px)')]]);
    });
    a(K, o, [[p.down, op(1, N), SE], [p.down + 120, op(1, 'translateY(2px)')], [p.up, op(1, 'translateY(2px)'), SE], [p.up + 200, op(1, N)]]);
    a(E, o, [[p.down, op(1), SE], [p.down + 120, op(0)], [p.up, op(0), SE], [p.up + 200, op(1)]]);
    a(R, o, [[p.down, op(0, 'scale(.92)'), SE], [p.down + 160, op(1, N)], [p.up, op(1, N), SE], [p.up + 120, op(0, N)]]);
    a(B, o, [[p.up, op(0), SE], [p.up + 120, op(1), BR], [p.out, op(1 - 0.65 * Math.min(1, (p.out - p.up - 120) / 600)), LE], [p.out + 120, op(0)]]);
    a(Pi, o, [[p.down, op(0, 'translateX(-4px)'), SE], [p.down + 160, op(1, N)], [p.out, op(1, N), LE], [p.out + 120, op(0, N)]]);
    a(Lr, o, [[p.up, op(1), SE], [p.up + 120, op(0)]]);
    a(Lw, o, [[p.up, op(0), SE], [p.up + 120, op(1)]]);
  }
  function on() { return vis && !d.hidden; }
  /* play() on a finished animation would start it over, so only paused ones play and finished ones never pause */
  function sync() { cur.forEach(function (x) { var st = x.playState; if (on()) { if (st == 'paused') x.play(); } else if (st != 'finished') x.pause(); }); }
  function run(i, g) {
    scene(i);
    if (!on()) cur.forEach(function (x) { x.pause(); });
    Promise.all(cur.map(function (x) { return x.finished; })).then(function () {
      if (g == gen) i + 1 < P.length ? run(i + 1, g) : (cur = []);
    }, function () {});
  }
  new IntersectionObserver(function (e) { vis = e[e.length - 1].intersectionRatio >= 0.15; sync(); }, { threshold: [0, 0.15] }).observe(s);
  d.addEventListener('visibilitychange', sync);
  s.parentNode.querySelector('.hero-replay').addEventListener('click', function () {
    gen++;
    all.forEach(function (x) { x.cancel(); });
    all = [];
    run(0, gen);
    cur.forEach(function (x) { x.currentTime = 400; });
    sync();
  });
  run(0, gen);
}`;
