import { attribution, attributionQuery } from '@/lib/analytics';
import { signIn } from '@/lib/auth';

/** redirectTo with the visitor's ?ref= and utm_* on it (before any #fragment), so the download can name the source. */
export function withAttribution(redirectTo: string, form: FormData | null): string {
  const q = form ? attributionQuery(attribution(form)) : '';
  if (!q) return redirectTo;
  const [path, hash] = redirectTo.split('#');
  return `${path}${path.includes('?') ? `&${q.slice(1)}` : q}${hash === undefined ? '' : `#${hash}`}`;
}

/**
 * Google sign-in through backant's next-auth setup, then back to `redirectTo` on this site. A real form, so it works
 * without JavaScript. On the landing page, StoryMotion adds the visit's ?ref= and utm_* as hidden fields.
 */
export function SignInButton({
  redirectTo,
  children = 'Continue with Google',
  className = 'btn',
  formClassName,
}: {
  redirectTo: string;
  children?: React.ReactNode;
  className?: string;
  formClassName?: string;
}) {
  return (
    <form
      className={formClassName}
      action={async (form: FormData) => {
        'use server';
        await signIn('google', { redirectTo: withAttribution(redirectTo, form) });
      }}
    >
      <button type="submit" className={className}>
        {children}
      </button>
    </form>
  );
}
