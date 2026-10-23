import { SITE_URL } from './site';

/**
 * The words of the three trial emails, in one place for Pavel to approve (the PR carries them as they read here).
 * Brand voice (BRAND.md): lowercase shepetal, short plain sentences, no exclamation marks, no AI model named, every
 * claim literally true. "100% private. Your data is yours." always comes with its proof sentence.
 */
export type Kind = 'welcome' | 'day3' | 'day25';
/**
 * `cta`: the button, right after the paragraph `after`. `boxed`: the paragraph shown in the price box.
 * The text part has neither: the paragraphs already carry the link.
 */
export type Copy = { subject: string; paragraphs: string[]; cta?: { label: string; href: string; after: string }; boxed?: string };

const QUESTIONS = 'Questions? Reply to this email. It comes to me.';
const SIGN_OFF = 'Pavel';
const INSTALL = `Not installed yet? Here is how: ${SITE_URL}/install`;
const ACCOUNT = `Both are on your account page: ${SITE_URL}/account`;
const PRICES = '$23.99 once. Yours forever.\n$0.99 a month.';

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
          INSTALL,
          QUESTIONS,
          SIGN_OFF,
        ],
        cta: { label: 'How to install', href: `${SITE_URL}/install?ref=email-welcome`, after: INSTALL },
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
          PRICES,
          ACCOUNT,
          'You can cancel the monthly plan on the same page at any time.',
          QUESTIONS,
          SIGN_OFF,
        ],
        boxed: PRICES,
        cta: { label: 'Choose a plan', href: `${SITE_URL}/account?ref=email-day25#plans`, after: ACCOUNT },
      };
  }
}

const days = (n: number) => (n === 1 ? '1 day' : `${n} days`);

/** The footer of every trial email: why it came, the unsubscribe link, and who sends it. */
export const footer = (unsubscribeUrl: string) => [
  `You get this email because you started a shepetal trial. It is one of three. To get no more: ${unsubscribeUrl}`,
  'BackAnt, Inc., 131 Continental Dr, Suite 305, Newark, DE 19713, USA',
];

// The landing page's palette (src/styles/site.css): paper, ink, secondary ink, rule and the signal orange.
const BG = '#E6E4DE';
const INK = '#161512';
const INK2 = '#57544E';
const RULE = '#D3D0C9';
const SIGNAL = '#FF4F12';
const FONT = "-apple-system,BlinkMacSystemFont,'Helvetica Neue',Helvetica,Arial,sans-serif";

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#x27;');
// The site's own links become links in the HTML part, shown without https://. No other URL appears in the copy.
const linked = (s: string) =>
  esc(s)
    .replace(/https:\/\/[^\s<]+/g, (u) => `<a href="${u}" style="color:${INK};text-decoration:underline">${u.replace('https://', '')}</a>`)
    .replace(/\n/g, '<br>');

/**
 * The text part and the branded HTML part of an email: a table layout with inline styles (what mail apps render),
 * the wordmark linked to the site with ?ref=email-<kind>, the price box and the button where the copy has them.
 */
export function render(kind: Kind, copy: Copy, unsubscribeUrl: string): { subject: string; text: string; html: string } {
  const foot = footer(unsubscribeUrl);
  const text = [...copy.paragraphs, '--', ...foot].join('\n\n') + '\n';
  const rows = copy.paragraphs.map((s) => {
    let style = `margin:0 0 16px;font:400 17px/1.55 ${FONT};color:${INK}`;
    if (s === copy.boxed) style = `margin:0 0 16px;font:600 19px/1.5 ${FONT};color:${INK};padding:14px 18px;border-left:3px solid ${SIGNAL};background:#EDEBE6`;
    if (s === SIGN_OFF) style = `margin:0 0 4px;font:italic 400 22px/1.3 Georgia,'Bodoni 72','Times New Roman',serif;color:${INK}`;
    const p = `<p style="${style}">${linked(s)}</p>`;
    if (!copy.cta || s !== copy.cta.after) return p;
    return (
      p +
      '<table role="presentation" cellpadding="0" cellspacing="0" style="margin:4px 0 24px"><tr>' +
      `<td style="background:${INK};border-radius:4px"><a href="${esc(copy.cta.href)}" style="display:inline-block;padding:14px 22px;font:600 16px/1 ${FONT};color:${BG};text-decoration:none">${esc(copy.cta.label)}</a></td>` +
      '</tr></table>'
    );
  });
  const html =
    '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
    `<meta name="color-scheme" content="light only"><title>${esc(copy.subject)}</title></head>\n` +
    `<body style="margin:0;padding:0;background:${BG}">\n` +
    `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${BG}"><tr><td align="center" style="padding:32px 16px">\n` +
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px">\n' +
    `<tr><td style="padding:0 0 28px"><a href="${SITE_URL}/?ref=email-${kind}"><img src="${SITE_URL}/press/shepetal-wordmark-ink.png" width="132" alt="shepetal" style="display:block;width:132px;height:auto;border:0"></a></td></tr>\n` +
    `<tr><td style="padding:0 0 8px;border-top:2px solid ${SIGNAL}"></td></tr>\n` +
    `<tr><td style="padding:20px 0 8px">${rows.join('')}</td></tr>\n` +
    `<tr><td style="padding:20px 0 0;border-top:1px solid ${RULE}">${foot.map((s) => `<p style="margin:0 0 8px;font:400 13px/1.5 ${FONT};color:${INK2}">${linked(s)}</p>`).join('')}</td></tr>\n` +
    '</table></td></tr></table></body></html>';
  return { subject: copy.subject, text, html };
}
