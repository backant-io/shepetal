import type { Metadata } from 'next';
import { SignIn } from '@/components/site/SignIn';

export const metadata: Metadata = { title: 'Sign in', robots: { index: false } };

/**
 * The sign-in page, static. worker.ts sends a signed-in visit on to ?next=, and sets the form's return path and the
 * failed line (?error=, where a failed Google sign-in lands) on the built page.
 */
export default function LoginPage() {
  return <SignIn />;
}
