import type { Metadata } from 'next';
import { Story } from '@/components/story/Story';

export const metadata: Metadata = { alternates: { canonical: '/' } };

export default function Home() {
  return <Story />;
}
