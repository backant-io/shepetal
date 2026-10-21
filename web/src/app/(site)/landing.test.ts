import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

// The landing page's hard rules (BRAND.md, brand/voice.md, the product facts). Each check guards a promise
// the page makes to the reader or a rule the brand set, so a copy edit that breaks one fails here.
const SRC = join(__dirname, '..', '..');
const read = (f: string) => readFileSync(f, 'utf8');
const page = read(join(__dirname, 'page.tsx'));
const layout = read(join(__dirname, 'layout.tsx'));
const legal = read(join(__dirname, 'legal', 'page.tsx'));
const hero = read(join(SRC, 'components', 'landing', 'Hero.tsx'));
const files = [
  join(__dirname, 'page.tsx'),
  join(__dirname, 'layout.tsx'),
  join(__dirname, 'legal', 'page.tsx'),
  ...readdirSync(join(SRC, 'components', 'landing')).map((f) => join(SRC, 'components', 'landing', f)),
];
const text = files.map(read).join('\n');
// What a reader sees: the source without comments, alt text and aria labels.
const strip = (src: string) =>
  src
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/^\s*\/\/.*$/gm, '')
    .replace(/\b(?:aria-label|alt)=(?:"[^"]*"|\{`[^`]*`\})/g, '');
const visible = strip(text);
// The hero's own words: its JSX text, without the code around it.
const words = (src: string) =>
  strip(src)
    .replace(/<[^>]*>|\{[^{}\n]*\}/g, ' ')
    .replace(/\s+/g, ' ');
const heroText = words(hero.split('export function Hero')[1]);
// The rest of the page as a reader sees it, below the hero.
const pageText = words(page.split('export default function Home')[1]);

describe('landing page', () => {
  it('names no speech recognition or AI model, so the privacy story is about the Mac and not a vendor', () => {
    expect(text).not.toMatch(/\b(Whisper|Parakeet|FluidAudio|OpenAI|GPT|Llama|Gemini|Claude|Qwen|Moonshine|Canary|NeMo|wav2vec)\b/);
    expect(visible).not.toMatch(/\bAI\b|\bmodel\b|\bLLM\b/);
  });

  it('loads nothing from another server and links to none, since the page makes its claims without citing sources', () => {
    expect(text.match(/https?:\/\/[^\s'"`)]+/g) ?? []).toEqual([]);
    expect(text).not.toMatch(/fonts\.googleapis|fonts\.gstatic|fontshare|backant\.io/);
  });

  it('starts the trial with the Google sign-in form, never a plain link, so the button works without JavaScript', () => {
    expect(hero).toContain("export const TRY = 'Try 30 days free'");
    const both = page + hero;
    const signIns = both.match(/<SignInButton redirectTo="\/account"/g)?.length ?? 0;
    expect(signIns).toBeGreaterThanOrEqual(4);
    // Google refuses sign-in inside in-app browsers such as X's, so on a phone each trial button has a
    // Send to my Mac next to it (CSS swaps them under 760 px).
    expect(both.match(/<SendToMac \/>/g)?.length).toBe(signIns);
  });

  it('gives each bold claim its own section, said once and as written (voice.md, The claims)', () => {
    for (const claim of [
      'Works in every app.',
      'Instant.',
      // 4×: the times sign, set small so it never reads as a capital X (words() spaces out the inline span)
      '4 × faster than typing.',
      '100% private. Your data is yours.',
      'Works offline.',
      'Meetings, transcribed on your Mac.',
      '$4.99. Yours forever.',
    ])
      expect(pageText.split(claim).length - 1, claim).toBe(1);
  });

  it('makes claims without proof apparatus, disclosures or hedges below the hero (Pavel, Oct 21)', () => {
    // Footnotes, the notes section, the privacy-detail links, the sign-in and roadmap lines, the fine print.
    for (const banned of ['<Ref', '<sup', 'id="note-', 'What goes online', 'Read the privacy details', 'Google sign-in', 'Sign in with Google'])
      expect(page, banned).not.toContain(banned);
    expect(pageText).not.toMatch(/in development|no dates|no card|Illustration|0\.1 s|measured on|M4 Pro/i);
    // A hedge undoes a bold claim.
    expect(pageText).not.toMatch(/\b(about|around|roughly|up to|depending on|typically|may|might)\b/i);
    // Quiet wordplay is not a brand line.
    expect(pageText).not.toMatch(/silent|makes no sound|keeps quiet/i);
  });

  it('keeps the footer to Privacy, Terms and Legal, and the notices on /legal', () => {
    const foot = layout.slice(layout.indexOf('<footer'));
    expect([...foot.matchAll(/<Link href="([^"]+)"/g)].map((m) => m[1])).toEqual(['/privacy', '/terms', '/legal']);
    expect(foot).not.toMatch(/trademark|Apache|License|©/);
    // Apache-2.0 asks for the NOTICE file to travel with the artwork; Apple asks for its trademark line.
    expect(legal).toContain('/brand/emoji/NOTICE.txt');
    expect(legal).toContain('/brand/emoji/LICENSE-Apache-2.0.txt');
    expect(legal).toContain('Mac and macOS are trademarks of Apple Inc.');
  });

  it('keeps the price and the steps off the link preview, as the brand asks, so a shared link sells the outcome', () => {
    const preview = [read(join(__dirname, 'layout.tsx')), read(join(SRC, 'app', 'layout.tsx'))]
      .flatMap((f) => [...f.matchAll(/\b(?:description|alt)\s*[:=]\s*'([^']*)'/g)].map((m) => m[1]));
    expect(preview.length).toBeGreaterThanOrEqual(3);
    for (const line of preview) expect(line).not.toMatch(/\$|\bonce\b|\bfree\b|hold fn|let go/i);
  });

  it('says what happens, never the steps: the instruction line is banned from brand copy (voice.md, Oct 21)', () => {
    expect(visible).not.toMatch(/hold fn,? (?:speak|talk)|speak, let go|hold fn and say|hold fn\. speak/i);
    expect(hero).toMatch(/>\s*Press one key\.\s*<\/h1>/);
    expect(hero).toMatch(/>\s*Your words appear wherever you speak\.\s*</);
  });

  it('keeps the hero bold and clean: no footnotes, no fine print, no instructions (Pavel, Oct 21)', () => {
    for (const banned of ['Hold fn', 'keeps quiet', 'macOS 14.4', 'Google sign-in', '0.1 s', 'Effortless', '<Ref'])
      expect(hero, banned).not.toContain(banned);
  });

  it('makes each claim in the hero once, since a claim said twice reads as filler', () => {
    const claims = ['Instant.', 'Works offline.', '100% private.', 'For Mac.', '30 days free.', '$4.99.', 'Yours forever.'];
    for (const claim of claims) expect(heroText.split(claim).length - 1, claim).toBe(1);
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
    // The hero's ring: the pill next to it says Recording while it is red and Writing while it is blue.
    expect(hero).toContain('<span className="hd-pill-rec">Recording</span>');
    expect(hero).toContain('<span className="hd-pill-write">Writing</span>');
    // Orange appears only in the hands-free scene, whose caption names it.
    expect(page).toContain('hands-free. The ring stays orange');
  });

  it('states the real system requirement once, in the FAQ, and names no other platform', () => {
    // The app's LSMinimumSystemVersion is 14.4 (meeting capture needs Core Audio process taps) and the build is arm64.
    expect(visible.match(/macOS 14\.4/g)?.length).toBe(1);
    expect(page).toContain("['Which Macs does it run on?', 'Macs with Apple silicon, on macOS 14.4 or later.']");
    // No build a visitor can download is out yet (/download says coming soon), so the page never says available now.
    expect(visible).not.toMatch(/macOS 14 or later|coming soon|available now|Linux|Windows|iPhone/i);
  });

  it('says a meeting records only after Record is clicked, with auto-record off by default', () => {
    // The card names the call app the way the app does: the bundle name of whoever uses the mic.
    expect(page).toContain('Meeting detected · zoom.us');
    expect(page).toContain('off until you turn it on');
    expect(page).toContain('Let people know before you record them.');
  });
});
