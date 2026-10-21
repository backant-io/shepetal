import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

// The landing page's hard rules (BRAND.md, brand/voice.md, the product facts). Each check guards a promise
// the page makes to the reader or a rule the brand set, so a copy edit that breaks one fails here.
const SRC = join(__dirname, '..', '..');
const read = (f: string) => readFileSync(f, 'utf8');
const page = read(join(__dirname, 'page.tsx'));
const files = [
  join(__dirname, 'page.tsx'),
  join(__dirname, 'layout.tsx'),
  join(SRC, 'components', 'HeroDemo.tsx'),
  ...readdirSync(join(SRC, 'components', 'landing')).map((f) => join(SRC, 'components', 'landing', f)),
];
const text = files.map(read).join('\n');
// What a reader sees: the source without comments, alt text and aria labels.
const visible = text
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .replace(/^\s*\/\/.*$/gm, '')
  .replace(/\b(?:aria-label|alt)=(?:"[^"]*"|\{`[^`]*`\})/g, '');

describe('landing page', () => {
  it('names no speech recognition or AI model, so the privacy story is about the Mac and not a vendor', () => {
    expect(text).not.toMatch(/\b(Whisper|Parakeet|FluidAudio|OpenAI|GPT|Llama|Gemini|Claude|Qwen|Moonshine|Canary|NeMo|wav2vec)\b/);
    expect(visible).not.toMatch(/\bAI\b|\bmodel\b|\bLLM\b/);
  });

  it('loads nothing from another server, and the only outside link is the cited speaking-rate source', () => {
    const urls = text.match(/https?:\/\/[^\s'"`)]+/g) ?? [];
    expect(urls.filter((u) => !u.startsWith('https://ncvs.org/'))).toEqual([]);
    expect(text).not.toMatch(/fonts\.googleapis|fonts\.gstatic|fontshare|backant\.io/);
  });

  it('starts the trial with the Google sign-in form, never a plain link, so the button works without JavaScript', () => {
    expect(page).toContain("const TRY = 'Try 30 days free'");
    expect(page.match(/<SignInButton redirectTo="\/account"/g)?.length).toBeGreaterThanOrEqual(4);
    expect(page).toContain('$4.99 once');
    expect(page).toContain('no card');
  });

  it('carries every approved line with its proof footnote, as the brand requires', () => {
    for (const [line, n] of [
      ['Effortless voice-to-text that transforms the way you work.', 1],
      ['100% private. Your data is yours.', 2],
      ['Instant, real-time, 4x faster.', 4],
    ] as const) {
      const at = page.indexOf(line);
      expect(at, line).toBeGreaterThan(-1);
      expect(page.slice(at, at + 200), line).toContain(`<Ref n={${n}} first />`);
      expect(page, `note ${n}`).toContain(`id="note-${n}"`);
    }
    // The measured latency keeps its conditions next to it.
    expect(page).toMatch(/measured on an M4 Pro\.\s*<Ref n=\{3\} first \/>/);
  });

  it('keeps the price and the steps off the link preview, as the brand asks, so a shared link sells the outcome', () => {
    const preview = [read(join(__dirname, 'layout.tsx')), read(join(SRC, 'app', 'layout.tsx'))]
      .flatMap((f) => [...f.matchAll(/\b(?:description|alt)\s*[:=]\s*'([^']*)'/g)].map((m) => m[1]));
    expect(preview.length).toBeGreaterThanOrEqual(3);
    for (const line of preview) expect(line).not.toMatch(/\$|\bonce\b|\bfree\b|hold fn|let go/i);
  });

  it('keeps the brand voice: no em dashes, no hype words, no invented proof', () => {
    expect(text).not.toContain('—');
    expect(visible).not.toMatch(/\b(seamless|magic|magical|revolutionary|blazing|lightning|supercharge|unlock|lifetime deal|cheap|fastest|best)\b/i);
    expect(visible).not.toMatch(/testimonial|★|users love|trusted by|rated/i);
  });

  it('spells the name lowercase and uses š only in the one line that explains it', () => {
    expect(visible).not.toMatch(/\bShepetal\b/);
    expect(visible.match(/š/g)?.length).toBe(1);
    expect(visible).not.toMatch(/háček|hacek/i);
  });

  it('draws 🤫 from the Noto file, since a typed 🤫 shows Apple’s artwork on a Mac', () => {
    expect(visible.replace(/alt="🤫"/g, '')).not.toContain('🤫');
    expect(text).toContain('/brand/emoji/emoji_u1f92b.svg');
  });

  it('names each indicator state in words next to its color, since color is never the only cue', () => {
    for (const [state, word] of [
      ['rec', 'Recording'],
      ['free', 'Hands-free'],
      ['write', 'Writing'],
    ])
      expect(page).toMatch(new RegExp(`<Ind state="${state}"[^>]*/>\\s*${word}`));
  });

  it('states the real system requirement and keeps the other platforms undated', () => {
    expect(visible).toContain('macOS 14.4 or later');
    expect(visible).not.toMatch(/macOS 14 or later|coming soon/i);
    expect(visible).toMatch(/Linux, Windows and iPhone are in development\. No dates yet\./);
  });

  it('says a meeting records only after Record is clicked, with auto-record off by default', () => {
    expect(page).toContain('Meeting detected · Zoom');
    expect(page).toContain('off until you turn it on');
    expect(page).toContain('Let people know before you record them.');
  });
});
