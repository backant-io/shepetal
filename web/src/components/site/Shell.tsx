import Link from 'next/link';
import { USE_CASES, useCasePath } from '@/lib/use-cases';
import { COMPARE_LINKS } from '@/lib/compare';

/** The "shepetal" wordmark in Bodoni Moda italic, as on the landing page. */
export function Wordmark({ small = false }: { small?: boolean }) {
  return (
    <Link className={small ? 's-mark s-mark-sm' : 's-mark'} href="/" prefetch={false}>
      shepetal
    </Link>
  );
}

/** The header of every page but the landing page: the wordmark, and one small link or action on the right. */
export function SiteHeader({ end }: { end?: React.ReactNode }) {
  return (
    <header className="s-head">
      <Wordmark />
      {end && <div className="s-head-end">{end}</div>}
    </header>
  );
}

/**
 * The footer, as on the landing page: the wordmark, the "Made for" pages, the "Compare" pages, the blog, then Privacy · Terms · Refunds · Legal,
 * and the cancellation button "Verträge hier kündigen" (§ 312k BGB: on every page, no sign-in, in exactly these words).
 */
export function SiteFooter() {
  return (
    <footer className="s-foot">
      <Wordmark small />
      <nav aria-label="Made for" className="s-mono s-foot-nav s-foot-for">
        <span>Made for</span>
        {USE_CASES.map((u) => (
          <Link key={u.slug} href={useCasePath(u.slug)} prefetch={false}>
            {u.label}
          </Link>
        ))}
      </nav>
      <nav aria-label="Compare" className="s-mono s-foot-nav s-foot-cmp">
        <span>Compare</span>
        {COMPARE_LINKS.map((c) => (
          <Link key={c.href} href={c.href} prefetch={false}>
            {c.label}
          </Link>
        ))}
      </nav>
      <nav aria-label="Blog" className="s-mono s-foot-nav">
        <Link href="/blog" prefetch={false}>Blog</Link>
      </nav>
      <nav aria-label="Legal" className="s-mono s-foot-nav">
        <Link href="/privacy" prefetch={false}>Privacy</Link>
        <Link href="/terms" prefetch={false}>Terms</Link>
        <Link href="/refunds" prefetch={false}>Refunds</Link>
        <Link href="/legal" prefetch={false}>Legal</Link>
        <Link href="/cancel" prefetch={false} lang="de">
          Verträge hier kündigen
        </Link>
      </nav>
    </footer>
  );
}
