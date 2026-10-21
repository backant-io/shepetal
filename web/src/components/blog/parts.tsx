import Link from 'next/link';
import { SignInButton } from '@/components/SignInButton';
import { KIND_LABEL } from '../../lib/blog/articles';
import type { Article } from '../../lib/blog/types';

export const formatDate = (iso: string) =>
  new Date(`${iso}T12:00:00Z`).toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC' });

/** Article cards for the index and "Read next". The whole card is the link. */
export function Cards({ list, large }: { list: Article[]; large?: boolean }) {
  return (
    <ul className="bl-cards" data-large={large || undefined}>
      {list.map((a) => (
        <li key={a.slug}>
          <Link href={`/blog/${a.slug}`} className="bl-card">
            <span className="bl-card-k">{KIND_LABEL[a.kind]}</span>
            <span className="bl-card-t">{a.title}</span>
            <span className="bl-card-d">{a.dek}</span>
          </Link>
        </li>
      ))}
    </ul>
  );
}

/**
 * The blog's one Mulberry field (the afterglow), with blush text only. The brand line, the canonical line and "For Mac.",
 * as written (no price until the new price lines are final); the other claims appear once each in the article itself (CTA_CLAIMS in seo.ts, checked in blog.test.ts).
 * "Try 30 days free" is the landing page's Google sign-in form (it starts the 30 days and lands on /account, where the
 * download is), so it works without JavaScript; "Buy shepetal" goes to the landing page's price section.
 */
export function BlogCta() {
  return (
    <section className="bl-cta" aria-labelledby="cta-h">
      <div className="bl-wrap">
        <img src="/brand/shepetal-wordmark-on-dark.svg" alt="shepetal" width={200} height={54} loading="lazy" decoding="async" className="bl-cta-mark" />
        <h2 id="cta-h">Write at the speed of thought.</h2>
        <p className="bl-cta-lead">Press one key. Your words appear wherever you speak.</p>
        <div className="bl-cta-row">
          <SignInButton redirectTo="/account" className="bl-btn">
            Try 30 days free
          </SignInButton>
          <Link href="/#price" className="bl-btn bl-btn-quiet">
            Buy shepetal
          </Link>
        </div>
        <p className="bl-cta-meta">For Mac.</p>
      </div>
    </section>
  );
}
