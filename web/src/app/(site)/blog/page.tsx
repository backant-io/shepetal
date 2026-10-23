import type { Metadata } from 'next';
import { BlogIndexPage } from '@/components/site/Blog';
import { BLOG } from '@/lib/blog';
import { pageMetadata } from '@/lib/seo';

export const metadata: Metadata = pageMetadata('blog', { title: BLOG.title, description: BLOG.description });

// Prerendered at build and served from the page cache (open-next.config.ts): the build fails if anything here is dynamic.
export const dynamic = 'error';

export default function Page() {
  return <BlogIndexPage />;
}
