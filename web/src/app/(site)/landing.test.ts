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

  it('loads nothing from another server, and the only outside links are the cited speaking and typing sources', () => {
    const urls = text.match(/https?:\/\/[^\s'"`)]+/g) ?? [];
    expect(urls.filter((u) => !u.startsWith('https://ncvs.org/') && !u.startsWith('https://doi.org/10.1145/'))).toEqual([]);
    expect(text).not.toMatch(/fonts\.googleapis|fonts\.gstatic|fontshare|backant\.io/);
  });

  it('starts the trial with the Google sign-in form, never a plain link, so the button works without JavaScript', () => {
    expect(page).toContain("const TRY = 'Try 30 days free'");
    const signIns = page.match(/<SignInButton redirectTo="\/account"/g)?.length ?? 0;
    expect(signIns).toBeGreaterThanOrEqual(4);
    // Google refuses sign-in inside in-app browsers such as X's, so on a phone each trial button has a
    // Send to my Mac next to it (CSS swaps them under 760 px).
    expect(page.match(/<SendToMac \/>/g)?.length).toBe(signIns);
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
    // 4x keeps the speaking source a reader can open, and never cites Karat et al.: in that study dictation with
    // corrections was slower than typing, so the link would argue against the line (brand/strategy.md, Evidence notes).
    const note4 = page.slice(page.indexOf('id="note-4"'), page.indexOf('</li>', page.indexOf('id="note-4"')));
    expect(note4).toContain('{NCVS}');
    expect(text).not.toMatch(/Karat|302979/);
    // The measured latency keeps its conditions next to it.
    expect(page).toMatch(/measured on an M4 Pro\.\s*<Ref n=\{3\} first \/>/);
  });

  it('keeps the price and the steps off the link preview, as the brand asks, so a shared link sells the outcome', () => {
    const preview = [read(join(__dirname, 'layout.tsx')), read(join(SRC, 'app', 'layout.tsx'))]
      .flatMap((f) => [...f.matchAll(/\b(?:description|alt)\s*[:=]\s*'([^']*)'/g)].map((m) => m[1]));
    expect(preview.length).toBeGreaterThanOrEqual(3);
    for (const line of preview) expect(line).not.toMatch(/\$|\bonce\b|\bfree\b|hold fn|let go/i);
  });

  it('says what happens, never the steps: the instruction line is banned from brand copy (voice.md, Oct 21)', () => {
    expect(visible).not.toMatch(/hold fn,? (?:speak|talk)|speak, let go|hold fn and say|hold fn\. speak/i);
    expect(page).toContain('Press one key. Your words appear wherever you speak.');
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
    // No build a visitor can download is out yet (/download says coming soon), so the page says Mac first, never available now.
    expect(visible).not.toMatch(/macOS 14 or later|coming soon|available now/i);
    expect(visible).toMatch(/Linux, Windows and iPhone are in development\. No dates yet\./);
  });

  it('says a meeting records only after Record is clicked, with auto-record off by default', () => {
    // The card names the call app the way the app does: the bundle name of whoever uses the mic.
    expect(page).toContain('Meeting detected · zoom.us');
    expect(page).toContain('off until you turn it on');
    expect(page).toContain('Let people know before you record them.');
  });
});
