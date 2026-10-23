import type { Metadata } from 'next';
import { GuidePage } from '@/components/site/Compare';
import { guideMetadata } from '@/lib/compare';

export const metadata: Metadata = guideMetadata('private-dictation-mac');

// Prerendered at build and served from the page cache (open-next.config.ts): the build fails if anything here is dynamic.
export const dynamic = 'error';

export default function Page() {
  return <GuidePage slug="private-dictation-mac" />;
}
