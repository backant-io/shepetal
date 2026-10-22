import type { Metadata } from 'next';
import Link from 'next/link';
import { SiteHeader } from '@/components/site/Shell';

export const metadata: Metadata = {
  title: 'Legal notice',
  description: 'Who runs shepetal and how to reach us (Impressum).',
  alternates: { canonical: '/impressum' },
};

// [COMPANY], [ADDRESS], [REPRESENTATIVE] and [REGISTRATION] are Pavel's details, filled in before launch.
export default function Impressum() {
  return (
    <>
      <SiteHeader end={<Link href="/account">Account</Link>} />
      <main className="s-main s-legal">
        <h1 className="s-h2">Legal notice</h1>
        <p className="s-mono">Impressum</p>

        <div className="s-prose">
          <h2>Provider</h2>
          <p>
            [COMPANY]
            <br />
            [ADDRESS]
          </p>

          <h2>Represented by</h2>
          <p>[REPRESENTATIVE]</p>

          <h2>Register</h2>
          <p>[REGISTRATION]</p>

          <h2>Contact</h2>
          <p>
            Email: <a href="mailto:founder@backant.io">founder@backant.io</a>
          </p>

          <h2>Responsible for the content</h2>
          <p>[REPRESENTATIVE], [ADDRESS]</p>

          <h2>Consumer disputes</h2>
          <p>
            We are not obliged and not willing to take part in dispute resolution proceedings before a consumer
            arbitration board.
          </p>

          <p>
            The terms for using shepetal are in the <Link href="/terms">Terms of Use</Link>, refunds in the{' '}
            <Link href="/refunds">Refund Policy</Link> and your data in the <Link href="/privacy">Privacy Policy</Link>.
          </p>
        </div>
      </main>
    </>
  );
}
