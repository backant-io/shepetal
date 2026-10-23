/**
 * The brand rules for public copy, as a check the tests run over the words a visitor reads (rendered text, metadata,
 * emails). Returns what breaks a rule, empty when the copy is clean.
 */
const RULES: [string, RegExp][] = [
  ['em dash', /—/],
  ['capital Shepetal', /Shepetal/],
  ['hedge', /\b(about|around|roughly|up to|typically|may|might|arguably|essentially|fundamentally)\b/i],
  ['banned line', /hold (the )?fn|fn, (speak|talk)|dictation that keeps quiet/i],
  ['AI or a model', /\bAI\b|\b(claude|gpt|chatgpt|gemini|whisper|llama|parakeet)\b/i],
  ['footnote', /<sup\b|[¹²³†‡]|\[\d+\]/],
  // A measured ratio is never published; the one approved claim is "4x faster than typing.", word for word.
  ['speed ratio', /\b(?!4x faster than typing\.)\d+(\.\d+)?\s?(x|times) (faster|quicker)/i],
  // The sentence shapes the voice skill rewrites as what happens.
  ['contrast or negation', /\b(not a|rather than|instead of|does not|has no|never|on purpose|intentional|for the record|without|at the time of writing|nothing else)\b/i],
];

const APPROVED_PRICES = ['$23.99 once. Yours forever.', '$0.99 a month.'];

export function copyProblems(text: string): string[] {
  const found = RULES.filter(([, re]) => re.test(text)).map(([name, re]) => `${name}: "${text.match(re)![0]}"`);
  const prices = APPROVED_PRICES.reduce((t, p) => t.split(p).join(''), text);
  if (/[$€]\s?\d/.test(prices)) found.push('price outside the approved lines');
  if (/4x faster than typing/i.test(text) && !text.includes('4x faster than typing.')) found.push('4x claim reworded');
  return found;
}

/** The text of rendered HTML, the way a visitor reads it. */
export const visibleText = (html: string) =>
  html
    .replace(/<[^>]+>/g, ' ')
    .replace(/&#x27;|&#39;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/\s+/g, ' ')
    .trim();
