import { signIn } from '@/lib/auth';

/** Google sign-in through backant's next-auth setup, then back to `redirectTo` on this site. */
export function SignInButton({
  redirectTo,
  children = 'Sign in with Google',
  className = 'btn',
}: {
  redirectTo: string;
  children?: React.ReactNode;
  className?: string;
}) {
  return (
    <form
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
