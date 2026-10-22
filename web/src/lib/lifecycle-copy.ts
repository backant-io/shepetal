import { SITE_URL } from './site';

/**
 * The words of the three trial emails, in one place for Pavel to approve (the PR carries them as they read here).
 * Brand voice (BRAND.md): lowercase shepetal, short plain sentences, no exclamation marks, no AI model named, every
 * claim literally true. "100% private. Your data is yours." always comes with its proof sentence.
 */
export type Kind = 'welcome' | 'day3' | 'day25';
export type Copy = { subject: string; paragraphs: string[] };

const QUESTIONS = 'Questions? Reply to this email. It comes to me.';
const SIGN_OFF = 'Pavel';

/**
 * `trial`: the user is still on the free trial (a buyer gets the welcome without the trial line).
 * `daysLeft`: whole days until the trial ends, rounded up as /account counts them (day25 only).
 */
export function copyFor(kind: Kind, { trial = true, daysLeft = 5 }: { trial?: boolean; daysLeft?: number } = {}): Copy {
  switch (kind) {
    case 'welcome':
      return {
        subject: 'Welcome to shepetal',
        paragraphs: [
          'Hi,',
          ...(trial ? ['Your free trial runs for 30 days. No card needed.'] : []),
          'Press one key, and your words appear wherever your cursor is: mail, chat, code, notes. Works in every app.',
          '100% private. Your data is yours. Speech recognition runs on your Mac, and your voice never leaves it.',
          'Works offline. You go online once to sign in and download speech recognition. After that you can dictate on a plane.',
          `Not installed yet? Here is how: ${SITE_URL}/install`,
          QUESTIONS,
          SIGN_OFF,
        ],
      };
    case 'day3':
      return {
        subject: 'A tip for shepetal: your language',
        paragraphs: [
          'Hi,',
          'A tip for your first week.',
          'shepetal understands 25 European languages. Automatic picks the one you speak. To keep it on one language, choose it under Languages in the shepetal menu.',
          'You can change it again at any time.',
          QUESTIONS,
          SIGN_OFF,
        ],
      };
    case 'day25':
      return {
        subject: `Your shepetal trial ends in ${days(daysLeft)}`,
        paragraphs: [
          'Hi,',
          `Your free trial of shepetal ends in ${days(daysLeft)}. To keep dictating, choose a plan:`,
          '$23.99 once. Yours forever.\n$0.99 a month.',
          `Both are on your account page: ${SITE_URL}/account`,
          'You can cancel the monthly plan on the same page at any time.',
          QUESTIONS,
          SIGN_OFF,
        ],
      };
  }
}

const days = (n: number) => (n === 1 ? '1 day' : `${n} days`);

/** The footer of every trial email: why it came, the unsubscribe link, and who sends it. */
export const footer = (unsubscribeUrl: string) => [
  `You get this email because you started a shepetal trial. It is one of three. To get no more: ${unsubscribeUrl}`,
  'BackAnt, Inc., 131 Continental Dr, Suite 305, Newark, DE 19713, USA',
];

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
// The site's own links become links in the HTML part. No other URL appears in the copy.
const linked = (s: string) =>
  esc(s).replace(/https:\/\/[^\s<]+/g, (u) => `<a href="${u}" style="color:#9E3664">${u}</a>`).replace(/\n/g, '<br>');

/** The text and the simple HTML body of an email. */
export function render(copy: Copy, unsubscribeUrl: string): { subject: string; text: string; html: string } {
  const foot = footer(unsubscribeUrl);
  const text = [...copy.paragraphs, '--', ...foot].join('\n\n') + '\n';
  const p = (s: string, style = '') => `<p style="margin:0 0 16px${style}">${linked(s)}</p>`;
  const html =
    '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
    `<title>${esc(copy.subject)}</title></head>` +
    '<body style="margin:0;padding:24px 16px;background:#FAEEE8;color:#26141C;font:16px/1.5 -apple-system,BlinkMacSystemFont,\'Helvetica Neue\',Arial,sans-serif">' +
    '<div style="max-width:32rem;margin:0 auto">' +
    copy.paragraphs.map((s) => p(s)).join('') +
    `<hr style="border:0;border-top:1px solid #E0D3CE;margin:24px 0">` +
    foot.map((s) => p(s, ';font-size:13px;color:#6C5B5E')).join('') +
    '</div></body></html>';
  return { subject: copy.subject, text, html };
}
