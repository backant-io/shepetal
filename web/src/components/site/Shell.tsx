import Link from 'next/link';

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
 * The footer, as on the landing page: the wordmark, then Privacy · Terms · Refunds · Legal, and the cancellation button
 * "Verträge hier kündigen" (§ 312k BGB: on every page, no sign-in, in exactly these words).
 */
export function SiteFooter() {
  return (
    <footer className="s-foot">
      <Wordmark small />
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
