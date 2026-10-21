import type { Metadata } from 'next';
import { redirect } from 'next/navigation';
import { SignIn } from '@/components/site/SignIn';
import { auth } from '@/lib/auth';
import { safeNext } from '@/lib/next-path';

export const metadata: Metadata = { title: 'Sign in', robots: { index: false } };

/** The sign-in page. next-auth sends errors here too (lib/auth.ts, pages.error). */
export default async function LoginPage({ searchParams }: { searchParams: Promise<{ next?: string; error?: string }> }) {
  const { next, error } = await searchParams;
  const to = safeNext(next);
  if (!error && (await auth())?.user?.email) redirect(to);
  return <SignIn next={to} failed={!!error} />;
}
