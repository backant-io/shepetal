import { SiteFooter } from '@/components/site/Shell';
import '@/styles/site.css';

/**
 * Sign-in, the account and the legal pages, in the landing page's system: concrete-white ground, ink, one orange.
 * Each page brings its own header (the wordmark and the one link it needs); the footer is the landing page's.
 */
export default function SiteLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="s-page">
      {children}
      <SiteFooter />
    </div>
  );
}
