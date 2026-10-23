import type { Metadata } from 'next';
import { ComparePage } from '@/components/site/Compare';
import { comparisonMetadata } from '@/lib/compare';

export const metadata: Metadata = comparisonMetadata('apple-dictation');

// Prerendered at build and served from the page cache (open-next.config.ts): the build fails if anything here is dynamic.
export const dynamic = 'error';

export default function Page() {
  return <ComparePage slug="apple-dictation" />;
}
