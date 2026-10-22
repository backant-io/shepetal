import Link from 'next/link';
import { USE_CASES, useCasePath } from '@/lib/use-cases';

/** The "shepetal" wordmark in Bodoni Moda italic, as on the landing page. */
export function Wordmark({ small = false }: { small?: boolean }) {
  return (
    <Link className={small ? 's-mark s-mark-sm' : 's-mark'} href="/">
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

/** The footer, as on the landing page: the wordmark, the "Made for" pages, then Privacy · Terms · Refunds · Legal. */
export function SiteFooter() {
  return (
    <footer className="s-foot">
      <Wordmark small />
      <nav aria-label="Made for" className="s-mono s-foot-nav s-foot-for">
        <span>Made for</span>
        {USE_CASES.map((u) => (
          <Link key={u.slug} href={useCasePath(u.slug)}>
            {u.label}
          </Link>
        ))}
      </nav>
      <nav aria-label="Legal" className="s-mono s-foot-nav">
        <Link href="/privacy">Privacy</Link>
        <Link href="/terms">Terms</Link>
        <Link href="/refunds">Refunds</Link>
        <Link href="/legal">Legal</Link>
      </nav>
    </footer>
  );
}
