import type { Metadata } from 'next';
import Link from 'next/link';

export const metadata: Metadata = {
  title: 'Terms of Use',
  description: 'The terms for using shepetal, its free trial and the one-time purchase.',
  alternates: { canonical: '/terms' },
};

export default function TermsOfUse() {
  return (
    <main className="mx-auto max-w-3xl px-4 pt-16 sm:px-8">
      <h1 className="display text-[clamp(2.75rem,8vw,4.5rem)] leading-none">Terms of Use</h1>
      <p className="mt-4 text-sm text-[var(--hush)]">Version 1.0. Last revised on October 20, 2026</p>

      <div className="prose-legal mt-12">
        <p>
          This website (the &quot;Site&quot;) and the shepetal app (together, the
          &quot;Service&quot;) belong to Backant Inc. (&quot;Company&quot;, &quot;us&quot;, &quot;our&quot; and
          &quot;we&quot;). Certain features of the Service may be subject to additional guidelines, terms or rules,
          which will be posted on the Site in connection with such features and are incorporated by reference into
          these Terms.
        </p>
        <p className="uppercase">
          These Terms of Use (these &quot;Terms&quot;) set forth the legally binding terms and conditions that govern
          your use of the Service. By accessing or using the Service, you are accepting these Terms, and you represent
          and warrant that you have the right, authority and capacity to enter into these Terms. You may not access or
          use the Service or accept the Terms if you are not at least 18 years old. If you do not agree with all of the
          provisions of these Terms, do not access or use the Service.
        </p>
        <p className="uppercase">
          Please be aware that section 11 contains provisions governing how to resolve disputes between you and
          Company, including an agreement to arbitrate, a class action waiver and a jury trial waiver. Please read
          section 11 carefully.
        </p>

        <h2>1. Accounts</h2>
        <p>
          You sign in to the Service with your Google account (your &quot;Account&quot;). You are responsible for
          keeping your Account secure and for all activity that occurs under it, including on the Macs you connect to
          it. Tell us immediately at <a href="mailto:founder@backant.io">founder@backant.io</a> if you suspect
          unauthorized use. You may ask us to delete your Account at any time.
        </p>

        <h2>2. Free trial and purchase</h2>
        <p>
          Your free trial starts the first time you sign in to the Service and lasts 30 days. The trial needs no payment
          method, and it ends on its own without any charge.
        </p>
        <p>
          After the trial you can buy shepetal with a one-time payment of $4.99 USD. A purchase gives you a perpetual
          license to use shepetal, including the future updates we release, and there is no subscription or recurring
          charge. Payments are processed by Stripe under Stripe&apos;s own terms. If we change the price, the change
          applies only to purchases made afterwards.
        </p>

        <h2>3. License</h2>
        <p>
          Subject to these Terms, Company grants you a non-transferable, non-exclusive, revocable, limited license to
          use the Service for your own personal or internal business use, during your trial and, after a purchase,
          without time limit. The shepetal source code is published under the MIT License, and nothing in these Terms
          limits the rights that license gives you to the source code.
        </p>
        <p>
          You shall not (a) resell, sublicense or share your Account or license with others; (b) interfere with or
          circumvent the Service&apos;s sign-in or license checks; or (c) access the Site in order to disrupt it or to
          collect data from it at scale.
        </p>

        <h2>4. Acceptable use</h2>
        <p>
          You agree not to use the Service in a way that violates any third-party right or applicable law, including
          recording other people without the consent the law where you are requires.
        </p>

        <h2>5. Indemnification</h2>
        <p>
          You agree to indemnify and hold Company (and its officers, employees and agents) harmless, including costs and
          attorneys&apos; fees, from any claim or demand made by any third party due to or arising out of (a) your use of
          the Service, (b) your violation of these Terms or (c) your violation of applicable laws or regulations.
        </p>

        <h2>6. Third-party links</h2>
        <p>
          The Service may contain links to third-party websites and services, such as Stripe. They are not
          under the control of Company, and Company is not responsible for them.
        </p>

        <h2>7. Disclaimers</h2>
        <p className="uppercase">
          The Service is provided on an &quot;as-is&quot; and &quot;as available&quot; basis, and Company (and our
          suppliers) expressly disclaim any and all warranties and conditions of any kind, whether express, implied or
          statutory, including all warranties or conditions of merchantability, fitness for a particular purpose,
          title, quiet enjoyment, accuracy or non-infringement.
        </p>
        <p>Speech recognition can make mistakes, so check important text before you rely on it.</p>

        <h2>8. Limitation on liability</h2>
        <p className="uppercase">
          To the maximum extent permitted by law, in no event shall Company (or our suppliers) be liable to you or any
          third party for any lost profits, lost data, costs of procurement of substitute products, or any indirect,
          consequential, exemplary, incidental, special or punitive damages arising from or relating to these Terms or
          your use of, or inability to use, the Service.
        </p>
        <p className="uppercase">
          To the maximum extent permitted by law, notwithstanding anything to the contrary contained herein, our
          liability to you for any damages arising from or related to these Terms will at all times be limited to a
          maximum of fifty US dollars.
        </p>

        <h2>9. Term and termination</h2>
        <p>
          These Terms remain in full force and effect while you use the Service. We may suspend or terminate your
          Account if you use the Service in violation of these Terms.
        </p>

        <h2>10. Copyright policy</h2>
        <p>
          If you believe that one of our users is unlawfully infringing copyright through the use of the Service,
          please contact our designated Copyright Agent: Pavel Hegler, 5214f Diamond Heights Boulevard, San Francisco,
          CA 94131, US, telephone (415) 969-2829, <a href="mailto:privacy@backant.io">privacy@backant.io</a>.
        </p>

        <h2>11. Dispute resolution</h2>
        <p>
          You agree that any dispute between you and Company relating in any way to the Service or these Terms will be
          resolved by binding arbitration, rather than in court, on an individual basis.
        </p>
        <p>
          30-day right to opt out: you have the right to opt out of this agreement to arbitrate by sending written
          notice within 30 days after first becoming subject to it to 5214f Diamond Heights Boulevard, San Francisco,
          California 94131, or by email to <a href="mailto:founder@backant.io">founder@backant.io</a>.
        </p>

        <h2>12. Contact</h2>
        <p>
          Pavel Hegler, Backant Inc., 5214f Diamond Heights Boulevard, San Francisco, California 94131. Telephone +1
          (415) 969-2829. Email <a href="mailto:founder@backant.io">founder@backant.io</a>.
        </p>
        <p>
          See also our <Link href="/privacy">Privacy Policy</Link>.
        </p>
      </div>
    </main>
  );
}
