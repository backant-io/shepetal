import type { Metadata } from 'next';
import { ApproveDevice } from '@/components/ApproveDevice';
import { SignInButton } from '@/components/SignInButton';
import { auth } from '@/lib/auth';

export const metadata: Metadata = { title: 'Connect the app', robots: { index: false } };

// The app opens /device?code=USER_CODE (API.md). Sign in, check the code, approve.
export default async function DevicePage({ searchParams }: { searchParams: Promise<{ code?: string }> }) {
  const { code } = await searchParams;
  const userCode = (code ?? '').trim().toUpperCase().slice(0, 16);
  const email = (await auth())?.user?.email;

  return (
    <main className="mx-auto max-w-xl px-4 pt-16 sm:px-8">
      <h1 className="display text-[clamp(3rem,10vw,5rem)] leading-none">Connect the app</h1>
      {email ? (
        <>
          <p className="mt-6 text-lg leading-relaxed">
            {userCode
              ? 'Check that this code matches the one the Shepetal app shows on your Mac, then approve it.'
              : 'Type the code the Shepetal app shows on your Mac, then approve it.'}
          </p>
          <div className="mt-10">
            <ApproveDevice userCode={userCode} />
          </div>
          <p className="mt-16 border-t border-[var(--line)] pt-6 text-sm">
            Signed in as <span className="font-semibold">{email}</span>
          </p>
        </>
      ) : (
        <>
          <p className="mt-6 text-lg leading-relaxed">
            Sign in with your Google account to connect the Shepetal app on your Mac. If this is your first time, your
            30-day free trial starts now, with no credit card.
          </p>
          <div className="mt-10">
            <SignInButton redirectTo={`/device?code=${encodeURIComponent(userCode)}`} />
          </div>
        </>
      )}
    </main>
  );
}
