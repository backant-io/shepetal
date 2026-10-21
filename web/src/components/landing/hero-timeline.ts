/**
 * The hero demo's timeline: one key goes down, a line is spoken, the key comes up and the line lands, in a mail,
 * a chat and a terminal. All times are ms from the first paint. plan() does the arithmetic on the server and
 * HERO_JS, the inline script, only turns its times into WAAPI animations.
 */

export type App = 'mail' | 'chat' | 'term';

/** What is said in each app. The text that lands is the same words: shepetal writes what you say. */
export const SCENES: { app: App; said: string }[] = [
  { app: 'mail', said: 'Can you send me the address?' },
  { app: 'chat', said: 'Running late, start without me.' },
  { app: 'term', said: 'Add a retry to the upload, keep the tests green.' },
];

// Speech rhythm: a word takes 150 ms plus 30 ms a letter, and a comma or full stop adds a 200 ms breath.
const WORD_BASE = 150;
const PER_LETTER = 30;
const BREATH = 200;
const FIRST_WORD = 150; // the first word starts this long after the key goes down
// The app pastes the whole text as the key comes up (FnGesture): 100 ms is the paste, and the line appears at once.
export const WRITE_DELAY = 100;
export const LAND_MS = 180;
const FIRST_DOWN = 900; // the first press, once the stage (900 ms) and the mail window have settled
const WRITING_MIN = 600; // the blue ring shows at least this long, so Writing reads as a state and not a glitch
const LEAVE = 120; // the ring and the pill leave
const READ = 1000; // from the landed line to the next app
const SWAP = 560; // the window before steps back into the stack while the next one rises in front
const BEAT = 200; // from a settled window to the next press
/** After the last app: the stack of all three windows holds this long, then fades, and the pass starts over. */
export const HOLD = 3000;
export const FADE = 400;

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
  /** When the whole line lands in the window, as one paste. */
  land: number;
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
    const land = up + WRITE_DELAY;
    const landEnd = land + LAND_MS;
    const out = Math.max(up + WRITING_MIN, landEnd);
    scenes.push({ from, to: out + LEAVE, ...(swap === undefined ? {} : { swap }), down, said, up, land, landEnd, out });
    from = out + LEAVE;
    swap = landEnd + READ;
    down = swap + SWAP + BEAT;
  }
  return scenes;
}

/**
 * The browser half, called with plan() and { hold: HOLD, fade: FADE }. A plain string, so no compiled function is
 * ever stringified. Each scene's animations have fill 'both', so a scene not yet played shows its rest frame; the next
 * scene is made when they have all finished. After the last app the stack of windows holds, fades, and the pass starts
 * over. The pause button (WCAG 2.2.2) holds it, as does leaving the screen. It changes no DOM attributes before a click,
 * so React hydrates the server HTML as it is. Reduced motion: it returns at once and the finished frame stays.
 */
export const HERO_JS = `function (P, X) {
  var s = document.getElementById('hero-stage'), d = document;
  if (!s || !s.animate || matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  var q = function (c, r) { return (r || s).querySelectorAll(c); },
    W = q('.hd-win'), L = q('.hd-line'), S = q('.hd-said')[0], K = q('.hd-key')[0], E = q('.hd-key i')[0], R = q('.hd-rec')[0],
    B = q('.hd-write')[0], Pi = q('.hd-pill')[0], Lr = q('.hd-pill-rec')[0], Lw = q('.hd-pill-write')[0],
    btn = s.parentNode.querySelector('.hero-pause'),
    SE = 'cubic-bezier(.2,0,0,1)', LE = 'cubic-bezier(.4,0,1,1)', BR = 'cubic-bezier(.42,0,.58,1)', N = 'none', DN = 'translateY(4px) scale(.97)',
    all = [], cur = [], vis = false, held = false;
  function op(o, t) { return t == null ? { opacity: o } : { opacity: o, transform: t }; }
  /* a window n places back in the stack: higher and narrower, so its title bar shows above the one in front */
  function back(n) { return n ? 'translateY(' + -12 * n + 'px) scale(' + (1 - 0.05 * n) + ')' : N; }
  /* one animation through [time, style, easing to the next] steps, timed from the scene's start o */
  function a(el, o, f) {
    var t0 = f[0][0], n = f[f.length - 1][0] - t0;
    var x = el.animate(f.map(function (k) { return Object.assign({ offset: (k[0] - t0) / n, easing: k[2] || 'linear' }, k[1]); }),
      { delay: t0 - o, duration: n, fill: 'both' });
    cur.push(x); all.push(x);
  }
  function scene(i, again) {
    var p = P[i], o = p.from, w = W[i], c = q('.hd-caret', w);
    if (i) {
      for (var k = 0; k < i; k++) a(W[k], o, [[p.swap, op(1, back(i - 1 - k)), SE], [p.swap + 520, op(1, back(i - k))]]);
      a(w, o, [[p.swap, op(0, 'translateY(44px)'), SE], [p.swap + 80, op(1, 'translateY(38px)'), SE], [p.swap + 560, op(1, N)]]);
    } else if (again) {
      a(w, o, [[o, op(0, 'translateY(14px)'), SE], [o + 700, op(1, N)]]);
    }
    a(S, o, again ? [[o, op(0), SE], [o + 400, op(1)], [p.to, op(1)]] : [[o, op(1)], [p.to, op(1)]]);
    /* the carets switch in 1 ms: two keyframes at the same end offset can leave the compositor on the first one */
    a(c[0], o, [[o, op(1)], [p.up, op(1)], [p.up + 1, op(0)]]);
    a(c[1], o, [[o, op(0)], [p.landEnd, op(0)], [p.landEnd + 1, op(1)]]);
    /* the line lands whole, as the app pastes it, while the spoken words rise out of the bar towards it */
    a(q('.hd-words', w)[0], o, [[p.land, op(0), SE], [p.landEnd, op(1)]]);
    q('span', L[i]).forEach(function (e, j) { var t = p.said[j]; a(e, o, [[t, op(0), SE], [t + 120, op(1)]]); });
    a(L[i], o, [[p.land, op(1, N), SE], [p.land + 320, op(0, 'translateY(-28px)')]]);
    a(K, o, [[p.down, op(1, N), SE], [p.down + 90, op(1, DN)], [p.up, op(1, DN), SE], [p.up + 220, op(1, N)]]);
    a(E, o, [[p.down, op(1), SE], [p.down + 90, op(0)], [p.up, op(0), SE], [p.up + 220, op(1)]]);
    a(R, o, [[p.down, op(0, 'scale(.92)'), SE], [p.down + 160, op(1, N)], [p.up, op(1, N), SE], [p.up + 120, op(0, N)]]);
    a(B, o, [[p.up, op(0), SE], [p.up + 120, op(1), BR], [p.out, op(1 - 0.65 * Math.min(1, (p.out - p.up - 120) / 600)), LE], [p.out + 120, op(0)]]);
    a(Pi, o, [[p.down, op(0, 'translateX(-4px)'), SE], [p.down + 160, op(1, N)], [p.out, op(1, N), LE], [p.out + 120, op(0, N)]]);
    a(Lr, o, [[p.up, op(1), SE], [p.up + 120, op(0)]]);
    a(Lw, o, [[p.up, op(0), SE], [p.up + 120, op(1)]]);
  }
  /* the end: the bar steps aside and all three apps hold as a stack, then they fade and the pass starts over */
  function rest() {
    a(S, 0, [[0, op(1), LE], [X.fade, op(0)]]);
    /* the windows behind go first, while the front one still covers them, so no two are ever see-through at once */
    var h = X.hold + X.fade / 2;
    W.forEach(function (w, k) { a(w, 0, k < W.length - 1 ? [[X.hold, op(1), LE], [h, op(0)]] : [[h, op(1), LE], [h + X.fade / 2, op(0)]]); });
  }
  function on() { return vis && !held && !d.hidden; }
  /* play() on a finished animation would start it over, so only paused ones play and finished ones never pause */
  function sync() { cur.forEach(function (x) { var st = x.playState; if (on()) { if (st == 'paused') x.play(); } else if (st != 'finished') x.pause(); }); }
  function run(i, again) {
    cur = [];
    i < P.length ? scene(i, again) : rest();
    if (!on()) cur.forEach(function (x) { x.pause(); });
    Promise.all(cur.map(function (x) { return x.finished; })).then(function () {
      if (i < P.length) return run(i + 1, again);
      all.forEach(function (x) { x.cancel(); });
      all = [];
      run(0, true);
    }, function () {});
  }
  new IntersectionObserver(function (e) { vis = e[e.length - 1].intersectionRatio >= 0.15; sync(); }, { threshold: [0, 0.15] }).observe(s);
  d.addEventListener('visibilitychange', sync);
  btn.addEventListener('click', function () {
    held = !held;
    btn.setAttribute('aria-label', held ? 'Play the demo' : 'Pause the demo');
    sync();
  });
  run(0, false);
}`;
