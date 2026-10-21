import { SHUSH_SVG } from '@/components/shush';

export const contentType = 'image/svg+xml';

export default function Icon() {
  return new Response(SHUSH_SVG, { headers: { 'content-type': contentType } });
}
