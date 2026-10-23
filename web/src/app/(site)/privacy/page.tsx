import type { Metadata } from 'next';
import { pageMetadata } from '@/lib/seo';
import Link from 'next/link';
import { SiteHeader } from '@/components/site/Shell';

export const metadata: Metadata = pageMetadata('privacy', { title: 'Privacy Policy', description: 'How shepetal handles your information. Your voice and your text stay on your Mac.' });

export default function PrivacyPolicy() {
  return (
    <>
      <SiteHeader end={<Link href="/account" prefetch={false}>Account</Link>} />
      <main className="s-main s-legal">
        <h1 className="s-h2">Privacy Policy</h1>
        <p className="s-mono">Last updated: October 22, 2026</p>

        <div className="s-prose">
          <p>
            BackAnt, Inc. (the &quot;Company&quot;, &quot;we&quot;, &quot;us&quot; or &quot;our&quot;) makes shepetal, a
            dictation app for Mac, and runs this website at shepetal.app (the &quot;Site&quot;). The Site and the
            shepetal app together are the &quot;Service&quot;. This policy says what personal data we process when you use
            the Service, why, on which legal basis, who receives it, how long we keep it, and what your rights are.
            &quot;You&quot; refers to you, as a user of the Service. The legal bases are those of the EU General Data
            Protection Regulation (GDPR) and the UK GDPR.
          </p>

          <h2>I. Who is responsible</h2>
          <p>
            The controller of your data is BackAnt, Inc., a Delaware corporation, 131 Continental Dr, Suite 305, Newark,
            DE 19713, USA (see the <Link href="/impressum">legal notice</Link>). For anything about your data, including
            your rights below, write to <a href="mailto:support@shepetal.app">support@shepetal.app</a>. We have not
            appointed a data protection officer.
          </p>

          <h2>II. Your voice and your text</h2>
          <p>
            shepetal turns your speech into text with on-device speech recognition. Your recordings, the text made from
            them and your dictation history are stored on your Mac in shepetal&apos;s folder, and we never receive them.
            You can delete them at any time in the app or by deleting that folder.
          </p>
          <p>
            Hugging Face, Inc. (United States) hosts the speech recognition files at huggingface.co. When the app
            downloads speech recognition, or the cleanup files if you choose them in the 🤫 menu, Hugging Face receives
            your IP address and the technical details of the request, under its own privacy policy. We send it nothing
            else. Legal basis: Art. 6(1)(b) GDPR, a download you asked for.
          </p>

          <h2>III. What we process, why, and on which legal basis</h2>
          <h3>1. Visiting the Site</h3>
          <p>
            Our hosting provider, Cloudflare, receives every request: your IP address, your browser type, the page
            address, the time and the other technical details your browser sends. Our request logs keep these, together
            with ids of accounts and payments when a request fails. We use them to keep the Service running and secure.
            Legal basis: Art. 6(1)(f) GDPR, our legitimate interest in a working and secure Service.
          </p>
          <h3>2. Your account</h3>
          <p>
            You sign in with your Google account. Google gives us your email address, and also your name and profile
            picture. We store your email address with an account number, the date your free trial started and your
            plan: the lifetime license and when and with which payment you bought it, or a subscription with its status,
            its price and the date it is paid through, and your Stripe customer id. Your name and picture are only in
            the encrypted sign-in cookie in your browser, and we do not store them. Legal basis: Art. 6(1)(b) GDPR, the
            contract with you.
          </p>
          <p>
            When you buy, we also store when you asked at checkout for delivery right away, which ends your right of
            withdrawal. Legal basis: Art. 6(1)(f) GDPR, our legitimate interest in being able to prove it.
          </p>
          <h3>3. The app sign-in, license and updates</h3>
          <p>
            When you connect the shepetal app to your account, the Site gives it a one-time code, and the app trades it
            for an access token. We store only hashes of the code and of the token, the token with your email address
            and when it was created, last used and ended. The app sends the token when it checks your license, and asks
            the Site whether a new version is out. Legal basis: Art. 6(1)(b) GDPR, the contract with you.
          </p>
          <h3>4. Purchases</h3>
          <p>
            Payments are handled by Stripe. Your card details go straight to Stripe, and so do your name, email address,
            billing address (and a VAT ID, if you give one), which Stripe uses to work out the sales tax or VAT. We keep
            your Stripe customer id and receive the confirmation that you paid, the date of the payment and, for a
            subscription, its renewal date and whether a renewal payment failed. Legal basis: Art. 6(1)(b) GDPR, the
            contract with you. We keep payment and tax records because the law requires it: Art. 6(1)(c) GDPR for EU and
            member state tax law, and Art. 6(1)(f) GDPR, our legitimate interest in meeting US tax law.
          </p>
          <h3>5. Analytics</h3>
          <p>
            We count visits and a few product events on our own server. No analytics script runs in your browser, and
            nothing is stored on or read from your device for analytics: no cookies, no local storage, no fingerprinting
            in the browser.
          </p>
          <p>
            When you open a page, our server (a Cloudflare Worker) sends a page-view event to PostHog after the page has
            been delivered. It contains the page address, keeping only the campaign fields of the link (for example
            ?ref=producthunt or utm_source), the domain of the site that linked to us (never the full address), the
            device type (desktop, mobile or tablet), the operating system family without its version, and whether the
            page was found. We don&apos;t send your IP address, your full browser string or the full address you came
            from, and PostHog&apos;s IP location lookup is switched off. Requests from search engines, link previews and
            scripts are not counted.
          </p>
          <p>
            Our server also records these events: a download of the app; the app opening its sign-in page and you
            confirming the sign-in; the app checking for updates; the app&apos;s first license check after you sign in;
            and a completed purchase. A download carries the app version and the campaign fields of the link. The
            sign-in events carry which kind of app asked, the app version if the app sends it, and whether you were
            already signed in to the Site, never which account. An update check carries the app version. A first license
            check and a purchase carry your plan, under an id made by hashing your email address, which is not sent;
            PostHog keeps a profile under that id.
          </p>
          <p>
            Page views, downloads, sign-in events and update checks are linked only by a daily visitor id: a keyed hash
            (HMAC-SHA-256) of your IP address and browser string, made with a random key we generate for each calendar
            day (UTC). The key never leaves our server and is deleted after 48 hours. After that nobody, including us,
            can work out which IP address or browser an id belonged to, and the ids of different days can&apos;t be
            linked. Your IP address and browser string are used only for this calculation and are not stored or sent.
            Because nothing is stored on or read from your device for analytics, no consent is needed for it (§ 25
            TDDDG). The app itself sends no analytics, and nothing about what you dictate ever leaves your Mac.
          </p>
          <p>
            Legal basis: Art. 6(1)(f) GDPR, our legitimate interest in counting, in total, how many people visit,
            install and buy shepetal.
          </p>
          <h3>6. Email to us</h3>
          <p>
            Mail to support@shepetal.app is forwarded by Cloudflare to our mailbox. We use what you write to answer you.
            Legal basis: Art. 6(1)(b) GDPR when it is about your contract, otherwise Art. 6(1)(f) GDPR, our legitimate
            interest in answering you.
          </p>
          <h3>7. Cancellations</h3>
          <p>
            When you cancel with <Link href="/cancel" prefetch={false} lang="de">Verträge hier kündigen</Link>, we store
            what you sent: your email address, the type of cancellation and its reason, the contract, the end you asked
            for, the time, and what we did about it, and we send all of it, by email through Cloudflare, to our mailbox
            so that we can act on it. If the email address belongs to an account, the confirmation goes to it: once
            automatic confirmation emails are switched on, Amazon Web Services sends it for us; until then we send it by
            hand. To stop the form being misused, your IP address and the email address you entered are counted for one
            minute (at most 5 cancellations a minute) and not stored. Legal basis: Art. 6(1)(c) GDPR, our duty to accept and confirm
            cancellations (§&nbsp;312k of the German Civil Code), and Art. 6(1)(f) GDPR, our legitimate interest in being
            able to prove them.
          </p>

          <div className="s-box">
            <h3>Your right to object</h3>
            <p>
              Where we rely on our legitimate interests (Art. 6(1)(f) GDPR, sections 1, 2, 4, 5, 6 and 7 above), you can
              object at any time, on grounds relating to your particular situation (Art. 21 GDPR). Write to{' '}
              <a href="mailto:support@shepetal.app">support@shepetal.app</a>. We then stop, unless we have compelling
              legitimate grounds that override your interests, or we need the data to establish, exercise or defend
              legal claims.
            </p>
          </div>

          <h2>IV. Who receives your data</h2>
          <p>
            We share your data only as far as each recipient needs it. These providers process it for us, on our
            instructions:
          </p>
          <ul>
            <li>Cloudflare, Inc. (United States): hosting, the database, file storage, request logs, email forwarding and the emails that tell us of a cancellation.</li>
            <li>Amazon Web Services, Inc. (United States): sends the confirmation of a cancellation, once automatic confirmation emails are switched on (section III.7).</li>
            <li>Stripe, Inc. (United States): payments and tax. Stripe also uses payment data as its own controller, for example to prevent fraud and to meet its legal duties.</li>
            <li>PostHog, Inc. (United States): the analytics above.</li>
            <li>The provider of our mailbox, which receives mail sent to support@shepetal.app.</li>
          </ul>
          <p>These receive your data as controllers of their own, under their own privacy policies:</p>
          <ul>
            <li>Google LLC (United States): sign-in with your Google account.</li>
            <li>Hugging Face, Inc. (United States): the speech recognition downloads in section II.</li>
          </ul>
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
          <p>We do not sell, trade or rent your personal data.</p>

          <h2>V. Outside the EU and the UK</h2>
          <p>
            We are in the United States, and we and the recipients above process your data there. Where a recipient is
            certified under the EU-US Data Privacy Framework (and its UK Extension), the transfer relies on the European
            Commission&apos;s adequacy decision of July 10, 2023 (and the UK&apos;s adequacy regulations). Otherwise it
            relies on the European Commission&apos;s Standard Contractual Clauses (and the UK Addendum to them), in the
            recipient&apos;s data processing terms. Ask us for a copy at{' '}
            <a href="mailto:support@shepetal.app">support@shepetal.app</a>.
          </p>

          <h2>VI. How long we keep it</h2>
          <ul>
            <li>Your account, your plan and your app tokens: until you ask us to delete your account. An app token stops working at Sign out, or after 90 days without use.</li>
            <li>One-time codes for the app sign-in: valid for one minute, and deleted when used or, once expired, when the next code is issued.</li>
            <li>Our request logs: 3 days.</li>
            <li>The sign-in cookie: until you sign out, or 30 days after your last visit.</li>
            <li>Analytics: PostHog keeps events for as long as our PostHog plan does, 1 year on its free plan and 7 years on its paid plans. A profile stays until we delete it.</li>
            <li>Payment and tax records: as long as tax law requires, up to 10 years.</li>
            <li>Email to us: up to 3 years after the end of the year of our last exchange.</li>
            <li>Cancellations: 3 years after the end of the year you sent them, deleted by the next cancellation sent after that. The email that told us of it is kept like email to us. The counts that limit the form: one minute.</li>
          </ul>

          <h2>VII. What you have to give us</h2>
          <p>
            You need a Google account and its email address to have an account and to use the app: without them we
            cannot give you a trial or a license. To buy, Stripe needs your payment and billing details, which the law
            also requires for tax. To cancel without signing in, we need the email of your account to find your
            contract. Analytics are not needed for anything: the Service works the same without them. No analytics script
            runs in your browser. The server events in section III.5 do not depend on your browser, but you can object
            to them (see the box in section III).
          </p>

          <h2>VIII. No automated decisions</h2>
          <p>
            We make no decisions about you by automated means alone that have legal or similarly significant effects
            (Art. 22 GDPR). Your license follows the plan you bought. Stripe may check payments for fraud as its own
            controller.
          </p>

          <h2>IX. Your rights</h2>
          <p>
            You have the right to access your data, and to have it corrected, deleted or restricted, and to receive it in
            a portable format (Art. 15 to 18 and 20 GDPR), and the right to object above (Art. 21 GDPR). Email{' '}
            <a href="mailto:support@shepetal.app">support@shepetal.app</a>. Deleting your account ends your trial or
            license on our side. Everything shepetal stored on your Mac stays there until you delete it.
          </p>
          <p>
            You also have the right to complain to a data protection supervisory authority, in particular where you
            live, where you work or where you think the law was broken (Art. 77 GDPR). The EU authorities are listed by
            the <a href="https://www.edpb.europa.eu/about-edpb/about-edpb/members_en">European Data Protection Board</a>.
            In the UK it is the <a href="https://ico.org.uk/make-a-complaint/">Information Commissioner&apos;s Office</a>.
          </p>

          <h2>X. Children</h2>
          <p>
            The Service is for adults: our <Link href="/terms">Terms of Use</Link> require you to be at least 18. We do
            not knowingly collect information from anyone under 18. If we learn that we have, we will delete it as soon
            as possible. If you believe we have, please contact us at{' '}
            <a href="mailto:support@shepetal.app">support@shepetal.app</a>.
          </p>

          <h2>XI. How we protect information</h2>
          <p>
            We use encryption in transit, store app tokens only as hashes and limit who can access our systems. No
            method of storage or transmission is completely secure, so we cannot guarantee that your information will
            never be accessed, disclosed, altered or destroyed.
          </p>

          <h2>XII. Links to other websites</h2>
          <p>
            The Service may link to other websites, such as Stripe&apos;s checkout page. This Privacy Policy applies
            only to the Service, and the privacy policies of those websites apply to your use of them.
          </p>

          <h2>XIII. Changes to this Privacy Policy</h2>
          <p>
            We may change this policy at any time. We will tell you about significant changes by email or with a notice
            on the Site, and they take effect 30 days after that notice. Small changes and clarifications take effect
            immediately.
          </p>

          <h2>XIV. Contact us</h2>
          <p>
            BackAnt, Inc., 131 Continental Dr, Suite 305, Newark, DE 19713, USA. Email{' '}
            <a href="mailto:support@shepetal.app">support@shepetal.app</a>.
          </p>
        </div>
      </main>
    </>
  );
}
