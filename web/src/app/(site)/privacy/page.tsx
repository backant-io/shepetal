import type { Metadata } from 'next';
import { pageMetadata } from '@/lib/seo';
import Link from 'next/link';
import { SiteHeader } from '@/components/site/Shell';

export const metadata: Metadata = pageMetadata('privacy', { title: 'Privacy Policy', description: 'How shepetal handles your information. Your voice and your text stay on your Mac.' });

export default function PrivacyPolicy() {
  return (
    <>
      <SiteHeader end={<Link href="/account">Account</Link>} />
      <main className="s-main s-legal">
        <h1 className="s-h2">Privacy Policy</h1>
        <p className="s-mono">Last updated: October 22, 2026</p>

        <div className="s-prose">
          <p>
            BackAnt, Inc., a Delaware corporation (the &quot;Company&quot;, &quot;we&quot;, &quot;us&quot; or
            &quot;our&quot;), makes shepetal, a dictation app for Mac, and runs this website at shepetal.app (the
            &quot;Site&quot;). The Site and the shepetal app together are the &quot;Service&quot;. This Privacy Policy explains what information we collect when you use the
            Service, how we use it and how we protect it. &quot;You&quot; refers to you, as a user of the Service.
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
            date your free trial started and your plan: the lifetime license, or a subscription with its status and the
            date it is paid through.
          </p>
          <h3>2. Purchases</h3>
          <p>
            Payments are handled by Stripe. Your card details go straight to Stripe. We keep your Stripe customer ID and
            receive the confirmation that you paid, the date of the payment and, for a subscription, its renewal date
            and whether a renewal payment failed.
          </p>
          <h3>3. The app sign-in</h3>
          <p>
            When you connect the shepetal app to your account, we create an access token for it and store only a hash of
            that token. The app sends the token when it checks your license.
          </p>
          <h3>4. Cookies and logs</h3>
          <p>
            The Site uses a session cookie to keep you signed in. Our hosting provider records technical request logs,
            such as your IP address, browser type and the time of a request, which we use to keep the Service running
            and secure.
          </p>
          <h3>5. Analytics</h3>
          <p>
            We count visits and a few product events with PostHog, without cookies and without storing anything in your
            browser. For a page view, PostHog receives the page address, the referring site, your browser and device
            type and, like any server you connect to, your IP address, which we do not use to find out who or where you
            are. Each page view gets a new random id, so visits are not linked together. If your browser sends Do Not
            Track or Global Privacy Control, the Site sends nothing.
          </p>
          <p>
            Our server also records four events: a download of the app, the app&apos;s first license check after you
            sign in, the app checking for updates, and a completed purchase. A download and an update check carry the
            app version and the site that sent you (for example ?ref=producthunt), under an id made by hashing your IP
            address and browser together with the date, so it changes every day and neither your IP address nor your
            browser is sent or kept. A first license check and a purchase carry your plan, under an id made by hashing
            your email address, which is not sent. The app itself sends no analytics, and nothing about what you
            dictate ever leaves your Mac.
          </p>
          <h3>6. Children&apos;s privacy</h3>
          <p>
            The Service is not directed to anyone under the age of 13, and we do not knowingly collect information from
            anyone under 13. If we learn that we have, we will delete that information as soon as possible. If you
            believe we have collected such information, please contact us at{' '}
            <a href="mailto:support@shepetal.app">support@shepetal.app</a>.
          </p>

          <h2>III. How we use and share information</h2>
          <p>
            We use your information to run your account, check your license, process your purchase, answer your
            questions and send you messages about your account. We do not sell, trade or rent your personal information.
          </p>
          <p>
            We share information with the vendors that run parts of the Service for us, and only as far as they need it:
            Google for sign-in, Stripe for payments, Cloudflare, which hosts the site and serves the installer
            downloads, and PostHog, Inc. (United States) for the analytics above. They use it only at our direction.
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
            We use encryption in transit, store app tokens only as hashes and limit who can access our systems. No
            method of storage or transmission is completely secure, so we cannot guarantee that your information will
            never be accessed, disclosed, altered or destroyed, and by using the Service you acknowledge this risk.
          </p>

          <h2>V. Your rights</h2>
          <p>
            You can ask us for a copy of the information we hold about you, or ask us to correct or delete it, by
            emailing <a href="mailto:support@shepetal.app">support@shepetal.app</a>. Deleting your account ends your trial
            or license on our side. Everything shepetal stored on your Mac stays there until you delete it.
          </p>

          <h2>VI. Links to other websites</h2>
          <p>
            The Service may link to other websites, such as Stripe&apos;s checkout page. This Privacy Policy applies
            only to the Service, and the privacy policies of those websites apply to your use of them.
          </p>

          <h2>VII. Changes to this Privacy Policy</h2>
          <p>
            We may change this policy at any time. We will tell you about significant changes by email or with a notice
            on the Site, and they take effect 30 days after that notice. Small changes and clarifications take effect
            immediately.
          </p>

          <h2>VIII. Contact us</h2>
          <p>
            The controller of your information is BackAnt, Inc., 131 Continental Dr, Suite 305, Newark, DE 19713, USA
            (see the <Link href="/impressum">legal notice</Link>). We have not appointed a data protection officer. If
            you have any questions about this Privacy Policy, email us at{' '}
            <a href="mailto:support@shepetal.app">support@shepetal.app</a>.
          </p>
        </div>
      </main>
    </>
  );
}
