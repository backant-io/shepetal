import { BLOG_CSS } from './blog-css';

export default function BlogLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      <style href="shepetal-blog" precedence="default">
        {BLOG_CSS}
      </style>
      {children}
    </>
  );
}
