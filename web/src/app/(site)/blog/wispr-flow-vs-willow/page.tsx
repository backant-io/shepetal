import type { Metadata } from 'next';
import { BlogArticlePage } from '@/components/site/Blog';
import { articleMetadata } from '@/lib/blog';

export const metadata: Metadata = articleMetadata('wispr-flow-vs-willow');

// Prerendered at build and served from the page cache (open-next.config.ts): the build fails if anything here is dynamic.
export const dynamic = 'error';

export default function Page() {
  return <BlogArticlePage slug="wispr-flow-vs-willow" />;
}
