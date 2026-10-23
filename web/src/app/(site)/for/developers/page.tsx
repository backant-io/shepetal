import type { Metadata } from 'next';
import { UseCasePage } from '@/components/site/UseCase';
import { useCaseMetadata } from '@/lib/use-cases';

export const metadata: Metadata = useCaseMetadata('developers');

// Prerendered at build and served from the page cache (open-next.config.ts): the build fails if anything here is dynamic.
export const dynamic = 'error';

export default function Page() {
  return <UseCasePage slug="developers" />;
}
