import type { Metadata } from 'next';
import Link from 'next/link';

export const metadata: Metadata = {
  title: 'Privacy Policy',
  description: 'How shepetal handles your information. Your voice and your text stay on your Mac.',
  alternates: { canonical: '/privacy' },
};

export default function PrivacyPolicy() {
  return (
    <main className="mx-auto max-w-3xl px-4 pt-16 sm:px-8">
      <h1 className="display text-[clamp(2.75rem,8vw,4.5rem)] leading-none">Privacy Policy</h1>
      <p className="mt-4 text-sm text-[var(--hush)]">Last updated: October 20, 2026</p>

      <div className="prose-legal mt-12">
        <p>
          Backant Inc. (the &quot;Company&quot;, &quot;we&quot;, &quot;us&quot; or &quot;our&quot;) makes shepetal, a
          dictation app for Mac, and runs this website (the &quot;Site&quot;). The Site and the
          shepetal app together are the &quot;Service&quot;. This Privacy Policy explains what information we collect
          when you use the Service, how we use it and how we protect it. &quot;You&quot; refers to you, as a user of the
          Service.
        </p>
        <p>
          By using the Service you accept this Privacy Policy and our <Link href="/terms">Terms of Use</Link>.
        </p>

        <h2>I. Your voice and your text</h2>
        <p>
          shepetal turns your speech into text with on-device speech recognition. Your recordings, the text made from
          them and your dictation history are stored on your Mac in shepetal&apos;s folder, and we never receive them.
          You can delete them at any time in the app or by deleting that folder.
        </p>
        <p>
          The first time you set up shepetal, the app downloads its speech recognition files. Like any download, this
          request shares technical details such as your IP address with the server that hosts the files.
        </p>

        <h2>II. Information we collect</h2>
        <h3>1. Your account</h3>
        <p>
          You sign in with your Google account. Google tells us your email address, and we store it together with the
          date your free trial started and whether you bought shepetal.
        </p>
        <h3>2. Purchases</h3>
        <p>
          Payments are handled by Stripe. Your card details go straight to Stripe, and we receive the confirmation that
          you paid and the date of the payment.
        </p>
        <h3>3. The app sign-in</h3>
        <p>
          When you connect the shepetal app to your account, we create an access token for it and store only a hash of
          that token. The app sends the token when it checks your license.
        </p>
        <h3>4. Cookies and logs</h3>
        <p>
          The Site uses a session cookie to keep you signed in. Our hosting provider records technical request logs, such
          as your IP address, browser type and the time of a request, which we use to keep the Service running and
          secure.
        </p>
        <h3>5. Children&apos;s privacy</h3>
        <p>
          The Service is not directed to anyone under the age of 13, and we do not knowingly collect information from
          anyone under 13. If we learn that we have, we will delete that information as soon as possible. If you believe
          we have collected such information, please contact us at{' '}
          <a href="mailto:privacy@backant.io">privacy@backant.io</a>.
        </p>

        <h2>III. How we use and share information</h2>
        <p>
          We use your information to run your account, check your license, process your purchase, answer your
          questions and send you messages about your account. We do not sell, trade or rent your personal information.
        </p>
        <p>
          We share information with the vendors that run parts of the Service for us, and only as far as they need it:
          Google for sign-in, Stripe for payments, Cloudflare for hosting and GitHub, which serves the installer
          downloads. They use it only at our direction.
        </p>
        <p>
          We may share information with outside parties if we have a good-faith belief that access, use, preservation
          or disclosure of the information is reasonably necessary to meet any applicable legal process or enforceable
          governmental request; to enforce applicable Terms of Use, including investigation of potential violations;
          to address fraud, security or technical concerns; or to protect against harm to the rights, property or
          safety of our users or the public as required or permitted by law.
        </p>
        <p>
          If we undergo a business transaction such as a merger, an acquisition by another company or the sale of all
          or a portion of our assets, your information may be among the assets transferred, and any acquirer may
          continue to process it as set forth in this Privacy Policy.
        </p>

        <h2>IV. How we protect information</h2>
        <p>
          We use encryption in transit, store app tokens only as hashes and limit who can access our systems. No method
          of storage or transmission is completely secure, so we cannot guarantee that your information will never be
          accessed, disclosed, altered or destroyed, and by using the Service you acknowledge this risk.
        </p>

        <h2>V. Your rights</h2>
        <p>
          You can ask us for a copy of the information we hold about you, or ask us to correct or delete it, by
          emailing <a href="mailto:privacy@backant.io">privacy@backant.io</a>. Deleting your account ends your trial
          or license on our side. Everything shepetal stored on your Mac stays there until you delete it.
        </p>

        <h2>VI. Links to other websites</h2>
        <p>
          The Service may link to other websites, such as Stripe&apos;s checkout page. This Privacy Policy applies only
          to the Service, and the privacy policies of those websites apply to your use of them.
        </p>

        <h2>VII. Changes to this Privacy Policy</h2>
        <p>
          We may change this policy at any time. We will tell you about significant changes by email or with a notice
          on the Site, and they take effect 30 days after that notice. Small changes and clarifications take effect
          immediately.
        </p>

        <h2>VIII. Contact us</h2>
        <p>
          If you have any questions about this Privacy Policy, email us at{' '}
          <a href="mailto:privacy@backant.io">privacy@backant.io</a>.
        </p>
      </div>
    </main>
  );
}
