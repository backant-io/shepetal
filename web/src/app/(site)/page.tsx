import { HeroDemo } from '@/components/HeroDemo';
import { SignInButton } from '@/components/SignInButton';

const FEATURES = [
  {
    title: 'Private',
    body: 'Shepetal uses on-device speech recognition, so your voice and your text stay on your Mac. Nothing leaves your computer, and it works the same on a plane with the Wi-Fi off.',
  },
  {
    title: 'Fast',
    body: 'The text is in place a moment after you let go of fn, because your Mac does all the work right there on its own chip.',
  },
  {
    title: 'Every app',
    body: 'Shepetal pastes the text wherever your cursor is: your mail, a chat, your code editor or a text field in the browser. It fits the words into the sentence around your cursor and puts your clipboard back right after.',
  },
  {
    title: 'Meetings next',
    body: 'We are working on meetings. Shepetal will listen along to a call on your Mac and give you the transcript, and it stays on your computer like everything else.',
  },
];

export default function Home() {
  return (
    <main className="mx-auto max-w-6xl px-4 sm:px-8">
      <section className="grid gap-12 pb-24 pt-10 sm:pt-16 lg:grid-cols-[1.4fr_1fr] lg:items-end">
        <div>
          <HeroDemo />
        </div>
        <div className="max-w-md">
          <p className="text-lg leading-relaxed">
            Shepetal is dictation that runs fully on your Mac. You hold fn, say what you want to write and let go, and
            the text lands where your cursor is.
          </p>
          <p className="mt-4 leading-relaxed text-[var(--hush)]">
            While it runs, a tiny 🤫 sits in the bottom-left corner of your screen, like the one on this page, and turns
            red while you talk.
          </p>
          <div className="mt-8 flex flex-wrap items-center gap-x-5 gap-y-3">
            <SignInButton redirectTo="/account">Start free trial</SignInButton>
            <span className="text-sm text-[var(--hush)]">Free for 30 days, no credit card.</span>
          </div>
        </div>
      </section>

      <section aria-label="Why Shepetal" className="py-12">
        {FEATURES.map((f) => (
          <div key={f.title} className="grid gap-3 py-10 md:grid-cols-[1fr_1.4fr] md:gap-12">
            <h2 className="display text-[clamp(2.25rem,5vw,3.5rem)] leading-none">{f.title}</h2>
            <p className="max-w-[60ch] text-lg leading-relaxed md:pt-2">{f.body}</p>
          </div>
        ))}
      </section>

      <section aria-labelledby="price" className="mt-12 rounded-[28px] bg-[var(--raised)] px-6 py-14 sm:px-12 sm:py-20">
        <h2 id="price" className="display text-[clamp(2.75rem,8vw,6rem)] leading-[0.95]">
          <span className="block">30 days free.</span>
          <span className="block">Then $4.99, once.</span>
        </h2>
        <p className="mt-8 max-w-[52ch] text-lg leading-relaxed">
          Start without a credit card. When the trial ends you pay $4.99 one time, and Shepetal is yours forever, future
          updates included.
        </p>
        <div className="mt-10 flex flex-wrap items-center gap-x-5 gap-y-3">
          <SignInButton redirectTo="/account">Start free trial</SignInButton>
          <span className="text-sm text-[var(--hush)]">Needs macOS 14 or later.</span>
        </div>
      </section>
    </main>
  );
}
