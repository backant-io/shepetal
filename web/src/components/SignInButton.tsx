import { signIn } from '@/lib/auth';

/** Google sign-in through backant's next-auth setup, then back to `redirectTo` on this site. A real form, so it works without JavaScript. */
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
      action={async () => {
        'use server';
        await signIn('google', { redirectTo });
      }}
    >
      <button type="submit" className={className}>
        {children}
      </button>
    </form>
  );
}
