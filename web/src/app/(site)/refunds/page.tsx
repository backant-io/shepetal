import type { Metadata } from 'next';
import { pageMetadata } from '@/lib/seo';
import Link from 'next/link';
import { SiteHeader } from '@/components/site/Shell';

export const metadata: Metadata = pageMetadata('refunds', { title: 'Refund Policy', description: 'Try shepetal free for 30 days. A full refund within 14 days of a lifetime purchase, and cancel a subscription anytime.' });

// The rules are the Terms of Use's (section 2, Refunds) and what the payment code does: a refunded lifetime license
// ends, a cancelled subscription runs to the end of its paid month, and a second charge for the same thing is refunded.
export default function Refunds() {
  return (
    <>
      <SiteHeader end={<Link href="/account">Account</Link>} />
      <main className="s-main s-legal">
        <h1 className="s-h2">Refund Policy</h1>
        <p className="s-mono">Last updated: October 22, 2026</p>

        <div className="s-prose">
          <p>
            This policy is part of our <Link href="/terms">Terms of Use</Link>. shepetal is sold by BackAnt, Inc. (see the{' '}
            <Link href="/impressum">legal notice</Link>).
          </p>

          <h2>Try it first</h2>
          <p>
            Every account starts with 30 days of shepetal, free, with no card. You pay only if you want to keep it after
            that.
          </p>

          <h2>Lifetime license, $23.99 once</h2>
          <p>
            If shepetal does not work for you, write to{' '}
            <a href="mailto:support@shepetal.app">support@shepetal.app</a> within 14 days of the purchase, from the email of
            your account, for a full refund. The license ends when the refund is made.
          </p>

          <h2>Monthly subscription, $0.99 a month</h2>
          <p>
            Cancel anytime on your <Link href="/account">account page</Link>, under Settings. shepetal keeps working until
            the end of the month you have paid for, and nothing is charged again. A month you have already started is
            not refunded.
          </p>
          <p>
            If you switch to the lifetime license, the subscription ends at once with no further charge. The months
            before the switch are not refunded.
          </p>

          <h2>Charged twice</h2>
          <p>
            If you pay twice for the same thing, for example a second lifetime license or a subscription next to a
            lifetime license, the extra payment is refunded on its own. If you ever see a charge you do not recognise,
            write to us and we will sort it out.
          </p>

          <h2>Your rights</h2>
          <p>This policy does not limit any refund right that the law where you live gives you.</p>

          <h2>Contact</h2>
          <p>
            Email <a href="mailto:support@shepetal.app">support@shepetal.app</a> with the email of your account and the date
            of the payment.
          </p>
        </div>
      </main>
    </>
  );
}
