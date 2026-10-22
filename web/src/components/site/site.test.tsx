import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { safeNext } from '@/lib/next-path';

const { SignIn } = await import('./SignIn');

describe('sign-in page', () => {
  const html = renderToStaticMarkup(<SignIn />);

  it('has one clear action, Continue with Google, as the page’s only orange, in a real form', () => {
    expect(html).toContain('<h1 class="s-h1">Sign in.</h1>');
    expect(html.match(/s-btn-signal/g)).toHaveLength(1);
    // A plain POST that works without JavaScript: no server action, the return path in the action (worker.ts sets it).
    expect(html).toContain(
      '<form class="s-form" action="/api/auth/signin/google?callbackUrl=%2Faccount" method="post"><button type="submit" class="s-btn s-btn-signal">Continue with Google</button></form>',
    );
    expect(renderToStaticMarkup(<SignIn next="/app/login?state=a b" />)).toContain('action="/api/auth/signin/google?callbackUrl=%2Fapp%2Flogin%3Fstate%3Da%20b"');
    expect(html.match(/<button\b/g)).toHaveLength(1);
  });

  it('keeps the key small, beside the heading, and says what failed when Google sends the user back', () => {
    expect(html).toContain('class="s-key"');
    expect(html).toContain('class="kd-art"');
    // Always in the page, hidden until ?error= (worker.ts drops `hidden`: hydration leaves attributes alone).
    expect(html).toContain('<p role="alert" class="s-alert" hidden="">Sign-in did not finish. Try again.</p>');
    expect(renderToStaticMarkup(<SignIn failed />)).toContain('<p role="alert" class="s-alert">Sign-in did not finish. Try again.</p>');
  });

  it('keeps the voice: lowercase shepetal, no hedges, no sign-in mechanics', () => {
    const text = html.replace(/<svg[\s\S]*?<\/svg>/g, '').replace(/<[^>]+>/g, ' ');
    expect(text).not.toMatch(/Shepetal|may|might|no card|only for the license/);
  });
});

describe('where a sign-in returns to', () => {
  it('stays on this site', () => {
    expect(safeNext('/account#plans')).toBe('/account#plans');
    expect(safeNext('/account?purchased=1')).toBe('/account?purchased=1');
    expect(safeNext('/app/login?redirect_uri=shepetal%3A%2F%2Fauth&state=a%20b')).toBe('/app/login?redirect_uri=shepetal%3A%2F%2Fauth&state=a%20b');
    expect(safeNext('/%09/evil.example')).toBe('/%09/evil.example'); // an encoded tab stays a path segment
    for (const bad of [undefined, null, '', 'https://evil.example/', '//evil.example/x', '/\\evil.example', 'account'])
      expect(safeNext(bad)).toBe('/account');
  });

  // A browser drops tabs and newlines from a URL and reads a backslash as a slash, so these are //evil.example to it;
  // dot segments resolve to //evil.example too. Each would make the signed-in /login redirect leave the site.
  it('never becomes another site once a browser resolves it', () => {
    for (const bad of ['/\t/evil.example', '/\n/evil.example', '/\r/evil.example', '/\x00/evil.example', '/\\evil.example',
      '/..//evil.example', '/.//evil.example', '/%2e%2e//evil.example', '/%2e//evil.example', '/a/..//evil.example', 'https://evil.example'])
      expect(safeNext(bad), JSON.stringify(bad)).toBe('/account');
    for (const x of ['/account', '/account?purchased=1#plans', '/a/../b', '/..//evil.example', '/%09/x'])
      expect(safeNext(safeNext(x))).toBe(safeNext(x));
  });
});

describe('install help (the app is not notarized)', () => {
  // shepetal runs on macOS 14.4 and later: macOS 15 and 14 word the refusal differently, and only 14 has Control-click.
  it('gives the four steps in order, for macOS 15 and 14: drag to Applications, close the message, Open Anyway, once', async () => {
    const { InstallSteps } = await import('./InstallSteps');
    const text = renderToStaticMarkup(<InstallSteps />).replace(/<[^>]+>/g, ' ').replace(/&amp;/g, '&').replace(/\s+/g, ' ');
    let at = 0;
    for (const s of ['Drag shepetal into Applications.', 'cannot open shepetal, or could not verify', 'on macOS 15, click Done', 'System Settings, then Privacy & Security', 'shepetal was blocked', 'Open Anyway', 'confirm with your password', 'On macOS 14 you can also Control-click shepetal', 'You do this once.']) {
      const i = text.indexOf(s, at);
      expect(i, s).toBeGreaterThan(-1);
      at = i;
    }
    expect(renderToStaticMarkup(<InstallSteps />).match(/<li>/g)).toHaveLength(4);
  });

  it('is where the account’s Download button lands, and that page starts the download', () => {
    const read = (p: string) => readFileSync(join(__dirname, '..', '..', 'app', '(site)', p, 'page.tsx'), 'utf8');
    expect(readFileSync(join(__dirname, '..', 'account', 'Account.tsx'), 'utf8')).toContain('href={`/install${from}`}');
    const install = read('install');
    // The refresh comes from worker.ts with ?ref= and utm_* (edge.test.ts). Rendered by React too, hydration added a
    // bare second one that browsers followed, and the download lost its attribution.
    expect(install).not.toMatch(/httpEquiv=["']refresh/i);
    // static: worker.ts adds ?ref= and utm_* to the /download link at the edge
    expect(install).toContain("const download = '/download';");
    expect(install).not.toContain('searchParams');
    expect(install).toContain('<InstallSteps />');
    expect(install).toContain('href={download}');
  });
});

describe('footer', () => {
  const nav = (html: string) => [...html.matchAll(/<nav aria-label="Legal"[\s\S]*?<\/nav>/g)][0][0];
  const footers = async () => {
    const { SiteFooter } = await import('./Shell');
    const { Story } = await import('@/components/story/Story');
    return [nav(renderToStaticMarkup(<SiteFooter />)), nav(renderToStaticMarkup(<Story />))];
  };

  it('reads Privacy · Terms · Refunds · Legal · Verträge hier kündigen, on the landing page and on every other page', async () => {
    const want = ['href="/privacy"', 'href="/terms"', 'href="/refunds"', 'href="/legal"', 'href="/cancel"'];
    for (const html of await footers()) expect(html.match(/href="[^"]+"/g)).toEqual(want);
  });

  // § 312k BGB: a subscription sold on the site needs a cancellation button on it, always there, labelled exactly
  // "Verträge hier kündigen" (or something as clear: no court has tested an English wording), leading to /cancel.
  it('carries the cancellation button in exactly the words the law gives, on both footers', async () => {
    for (const html of await footers()) expect(html).toMatch(/<a (?=[^>]*href="\/cancel")(?=[^>]*lang="de")[^>]*>Verträge hier kündigen<\/a>/);
  });
});

describe('cancelling without signing in (§ 312k BGB)', () => {
  const src = (p: string) => readFileSync(join(__dirname, '..', '..', p), 'utf8');

  it('is a static page that asks for nothing but what the law lists, then the Jetzt kündigen button', async () => {
    const { default: Cancel } = await import('@/app/(site)/cancel/page');
    const html = renderToStaticMarkup(<Cancel />);
    const main = html.slice(html.indexOf('<main'));
    const form = main.match(/<form [^>]*>/)?.[0] ?? '';
    expect(form).toContain('action="/api/cancel"');
    expect(form).toContain('method="post"');
    // type and reason, the contract, the end, the email that identifies it: nothing else (BGH I ZR 200/25).
    expect([...new Set([...main.matchAll(/<(?:input|textarea)[^>]*name="([^"]+)"/g)].map((m) => m[1]))]).toEqual(['kind', 'reason', 'contract', 'end', 'date', 'email']);
    expect(main.match(/<button\b[^>]*>[^<]*<\/button>/g)).toEqual(['<button type="submit" class="s-btn s-btn-signal">Jetzt kündigen</button>']);
    expect(main.match(/\brequired\b/g)).toHaveLength(1);
    expect(main.match(/<input type="email"[^>]*>/)?.[0]).toMatch(/required=""[^>]*name="email"|name="email"[^>]*required=""/);
    // no offer, no "keep it", no sign-in, no link away from the form
    expect(main).not.toMatch(/<a\b|<dialog|sign in|keep|lifetime for|\$/i);
    expect(html).not.toContain('href="/account"');
  });

  it('is reachable from the page for unknown paths too', async () => {
    const { default: NotFound } = await import('@/app/not-found');
    expect(renderToStaticMarkup(<NotFound />)).toMatch(/<a (?=[^>]*href="\/cancel")[^>]*>Verträge hier kündigen<\/a>/);
  });

  it('needs no sign-in anywhere on the way: no session on the page, none in the API, which worker.ts answers', () => {
    const page = src('app/(site)/cancel/page.tsx');
    expect(page).not.toMatch(/@\/lib\/auth|next-auth|searchParams|cookies\(|headers\(/);
    for (const f of ['app/api/cancel/route.ts', 'lib/cancel.ts']) expect(src(f)).not.toMatch(/@\/lib\/auth|['"]\.\/auth['"]|next-auth|requestUser|upsertUser/);
    expect(readFileSync(join(__dirname, '..', '..', '..', 'worker.ts'), 'utf8')).toContain("'POST /api/cancel': cancel,");
  });
});

describe('legal pages', () => {
  const page = (p: string) => readFileSync(join(__dirname, '..', '..', 'app', '(site)', p, 'page.tsx'), 'utf8');

  it('credit the fonts the site uses and keep the notices', () => {
    const legal = page('legal');
    for (const s of [
      '/fonts/licenses/Archivo-OFL.txt',
      '/fonts/licenses/BodoniModa-OFL.txt',
      '/fonts/licenses/FragmentMono-OFL.txt',
      '/brand/emoji/NOTICE.txt',
      '/brand/emoji/LICENSE-Apache-2.0.txt',
      'Mac and macOS are trademarks of Apple Inc.',
    ])
      expect(legal).toContain(s);
    for (const f of ['Archivo-OFL.txt', 'BodoniModa-OFL.txt', 'FragmentMono-OFL.txt'])
      expect(readFileSync(join(__dirname, '..', '..', '..', 'public', 'fonts', 'licenses', f), 'utf8')).toMatch(
        /SIL OPEN FONT LICENSE/i,
      );
  });

  it('have a legal notice that names the seller, linked from /legal', () => {
    const impressum = page('impressum');
    for (const p of ['BackAnt, Inc., a Delaware corporation', '131 Continental Dr, Suite 305', 'Newark, DE 19713', 'Pavel Hegler', 'file number 10279385', 'support@shepetal.app'])
      expect(impressum).toContain(p);
    expect(impressum).not.toMatch(/\[(COMPANY|ADDRESS|REPRESENTATIVE|REGISTRATION)\]/);
    expect(page('legal')).toContain('href="/impressum"');
  });

  it('have a refund policy that says what the terms and the payment code do', () => {
    const refunds = page('refunds').replace(/\s+/g, ' ');
    for (const s of ['30 days of shepetal, free', 'within 14 days of the purchase', '$23.99 once', '$0.99 a month', 'Cancel anytime', 'nothing is charged again', 'switch to the lifetime license'])
      expect(refunds).toContain(s);
    expect(page('terms').replace(/\s+/g, ' ')).toContain('within 14 days of a lifetime purchase for a full refund');
  });

  // What the code does, said where a customer reads it: a later end date on /cancel costs one more, shortened charge;
  // "right away" for good cause is decided by hand; and our own purchase confirmation goes out by email (§ 356(6) Nr. 2 d).
  it('say what a later end date and an extraordinary cancellation do, and that the purchase is confirmed by email', () => {
    for (const p of ['refunds', 'terms']) {
      const text = page(p).replace(/\s+/g, ' ');
      expect(text, p).toMatch(/[Tt]he subscription then renews once more, and that last charge covers only the days up to your date/);
      expect(text, p).toMatch(/end right away[.:] (It|it) stops renewing at once/);
      expect(text, p).toMatch(/we confirm (this|both) by email to the address of your account, with what you bought and the price you paid/);
      expect(text, p).not.toMatch(/receipt confirms/);
    }
  });

  // Directive 2011/83/EU Art. 6(1)(h) and (k): before the contract, the conditions, the time limit and the procedure
  // of the right of withdrawal, the model form, and when the right is lost. Missing, the period never starts
  // (§ 356(3) BGB) and runs for 12 months and 14 days (§ 356(4) BGB).
  it('give the full withdrawal information and the model withdrawal form, linked from the Terms and the checkout', () => {
    const refunds = page('refunds').replace(/\s+/g, ' ');
    for (const s of [
      'id="withdrawal"',
      'You have the right to withdraw from this contract within 14 days without giving any reason.',
      'The withdrawal period will expire after 14 days from the day of the conclusion of the contract',
      'by an unequivocal statement',
      'it is sufficient for you to send your communication concerning your exercise of the right of withdrawal before the withdrawal period has expired',
      'not later than 14 days from the day on which we are informed about your decision to withdraw',
      'you expressly agree that we begin before the withdrawal period ends, you acknowledge that you thereby lose your right of withdrawal',
      'Model withdrawal form',
      'I/We (*) hereby give notice that I/We (*) withdraw from my/our (*) contract',
      'Signature of consumer(s) (only if this form is notified on paper)',
      '(*) Delete as appropriate.',
    ])
      expect(refunds).toContain(s);
    expect(page('terms')).toContain('href="/refunds#withdrawal"');
  });

  // One address for support, refunds and privacy: the review found the Terms sending people to another one. The one
  // exception is the Copyright Agent of Terms section 10, whose address must match the US Copyright Office designation.
  it('give one contact address, support@shepetal.app, on every page', () => {
    const dir = join(__dirname, '..', '..', 'app', '(site)');
    const files = [
      ...readdirSync(dir, { recursive: true, encoding: 'utf8' }).filter((f) => f.endsWith('.tsx')).map((f) => join(dir, f)),
      ...['site', 'story', 'account'].flatMap((d) => readdirSync(join(__dirname, '..', d)).filter((f) => f.endsWith('.tsx')).map((f) => join(__dirname, '..', d, f))),
    ];
    const emails = new Set(files.flatMap((f) => readFileSync(f, 'utf8').match(/[\w.+-]+@[\w-]+(?:\.[\w-]+)+/g) ?? []));
    expect([...emails].filter((e) => !e.endsWith('@example.com')).sort()).toEqual(['privacy@backant.io', 'support@shepetal.app']);
    expect(page('terms').match(/privacy@backant\.io/g)).toHaveLength(2);
    expect(page('terms').replace(/\s+/g, ' ')).toMatch(/designated Copyright Agent: Pavel Hegler[^<]*<a href="mailto:privacy@backant\.io">/);
    for (const p of ['terms', 'privacy', 'refunds', 'faq', 'impressum', 'install']) expect(page(p), p).toContain('mailto:support@shepetal.app');
  });

  it('use the site’s header, type and prose', () => {
    for (const p of ['privacy', 'terms', 'legal', 'impressum', 'refunds']) {
      const src = page(p);
      expect(src).toContain('<SiteHeader');
      expect(src).toContain('className="s-prose"');
      expect(src).not.toMatch(/className="[^"]*\b(mx-auto|max-w-|text-\[|pt-16)\b/);
    }
  });
});
