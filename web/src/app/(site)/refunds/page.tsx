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
      <SiteHeader end={<Link href="/account" prefetch={false}>Account</Link>} />
      <main className="s-main s-legal">
        <h1 className="s-h2">Refund Policy</h1>
        <p className="s-mono">Last updated: October 22, 2026</p>

        <div className="s-prose">
          <p>
            This policy is part of our <Link href="/terms" prefetch={false}>Terms of Use</Link>. shepetal is sold by BackAnt, Inc. (see the{' '}
            <Link href="/impressum" prefetch={false}>legal notice</Link>).
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
            Cancel anytime on your <Link href="/account" prefetch={false}>account page</Link>, under Settings. You can
            also cancel without signing in: choose <Link href="/cancel" prefetch={false} lang="de">Verträge hier kündigen</Link>{' '}
            at the bottom of any page. shepetal keeps working until the end of the month you have paid for, and nothing
            is charged again. A month you have already started is not refunded.
          </p>
          <p>
            Without signing in you can also choose a later end date, at most three months after the month you have
            paid for. The subscription then renews once more, and that last charge covers only the days up to your
            date. Nothing is charged after it.
          </p>
          <p>
            For an extraordinary cancellation for good cause you can ask for the subscription to end right away. It
            stops renewing at once. We look at your reason, decide when it ends and what is refunded, and tell you by
            email.
          </p>
          <p>
            If you switch to the lifetime license, the subscription ends at once with no further charge. The months
            before the switch are not refunded.
          </p>

          {/* The withdrawal information of Directive 2011/83/EU Art. 6(1)(h) and (k), in the words of its Annex I (A),
              and the model withdrawal form of Annex I (B) (Art. 246a § 1(2) EGBGB, Anlage 1 and 2). */}
          <h2 id="withdrawal">Your right of withdrawal</h2>
          <p>
            If you are a consumer in the European Union, the United Kingdom or another country with this right, you have
            the following right of withdrawal.
          </p>
          <h3>Right of withdrawal</h3>
          <p>
            You have the right to withdraw from this contract within 14 days without giving any reason. The withdrawal
            period will expire after 14 days from the day of the conclusion of the contract: the day you buy the
            lifetime license or start the subscription.
          </p>
          <p>
            To exercise the right of withdrawal, you must inform us (BackAnt, Inc., 131 Continental Dr, Suite 305, Newark,
            DE 19713, USA, <a href="mailto:support@shepetal.app">support@shepetal.app</a>) of your decision to withdraw
            from this contract by an unequivocal statement, for example an email or a letter sent by post. You may use
            the model withdrawal form below, but it is not obligatory. To meet the withdrawal deadline, it is sufficient
            for you to send your communication concerning your exercise of the right of withdrawal before the withdrawal
            period has expired.
          </p>
          <h3>Effects of withdrawal</h3>
          <p>
            If you withdraw from this contract, we shall reimburse to you all payments received from you without undue
            delay and in any event not later than 14 days from the day on which we are informed about your decision to
            withdraw from this contract. We will carry out such reimbursement using the same means of payment as you used
            for the initial transaction, unless you have expressly agreed otherwise; in any event, you will not incur any
            fees as a result of such reimbursement.
          </p>
          <p>
            If you asked for the subscription to begin during the withdrawal period, you shall pay us an amount which is
            in proportion to what has been provided until you have told us of your withdrawal from this contract, in
            comparison with the full coverage of the contract.
          </p>
          <h3>When the right of withdrawal ends early</h3>
          <p>
            shepetal is digital content that is not supplied on a tangible medium. Your right of withdrawal ends before
            the 14 days are over as soon as we begin to supply it, which is right after you pay, because at checkout you
            expressly agree that we begin before the withdrawal period ends, you acknowledge that you thereby lose your
            right of withdrawal. After you pay, we confirm both by email to the address of your account, with what you
            bought and the price you paid, and your Stripe receipt says it too (§&nbsp;356(6) of the German Civil Code,
            Art. 16(m) of Directive 2011/83/EU). Where the monthly subscription counts as a service instead, the right ends only once
            the service has been provided in full (§&nbsp;356(5) of the German Civil Code), so you can withdraw within
            the 14 days and pay for the time up to then, as above. The 14-day refund on the lifetime license above
            applies anyway.
          </p>
          <h3>Model withdrawal form</h3>
          <p>(Complete and return this form only if you wish to withdraw from the contract.)</p>
          <div className="s-box">
            <p>
              To BackAnt, Inc., 131 Continental Dr, Suite 305, Newark, DE 19713, USA, support@shepetal.app:
              <br />I/We (*) hereby give notice that I/We (*) withdraw from my/our (*) contract for the supply of the
              following digital content (*)/for the provision of the following service (*):
              <br />Ordered on (*)/received on (*):
              <br />Name of consumer(s):
              <br />Address of consumer(s):
              <br />Signature of consumer(s) (only if this form is notified on paper):
              <br />Date:
            </p>
            <p>(*) Delete as appropriate.</p>
          </div>

          <h2>How refunds work</h2>
          <p>We refund to the card you paid with. Your bank shows it within 5 to 10 business days.</p>

          <h2>Charged twice</h2>
          <p>
            If you pay twice for the same thing, for example a second lifetime license or a subscription next to a
            lifetime license, the extra payment is refunded on its own. If you ever see a charge you do not recognise,
            write to us and we will sort it out.
          </p>

          <h2>Your rights</h2>
          <p>
            This policy does not limit any refund right that the law where you live gives you, including your rights if
            shepetal is faulty.
          </p>

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
