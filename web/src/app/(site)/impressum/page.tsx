import type { Metadata } from 'next';
import Link from 'next/link';
import { SiteHeader } from '@/components/site/Shell';

export const metadata: Metadata = {
  title: 'Legal notice',
  description: 'Who runs shepetal and how to reach us (Impressum).',
  alternates: { canonical: '/impressum' },
};

// The seller's details from Pavel's legal records (22.10.26). backant.io itself never mentions shepetal.
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
            BackAnt, Inc., a Delaware corporation
            <br />
            131 Continental Dr, Suite 305
            <br />
            Newark, DE 19713
            <br />
            USA
          </p>
          <p>This is the office of our registered agent.</p>

          <h2>Represented by</h2>
          <p>Pavel Hegler</p>

          <h2>Register</h2>
          <p>Delaware Secretary of State, file number 10279385</p>

          <h2>Contact</h2>
          <p>
            Email: <a href="mailto:support@shepetal.app">support@shepetal.app</a>
          </p>

          <h2>Responsible for the content</h2>
          <p>Pavel Hegler, at the address above</p>

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
