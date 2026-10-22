import { download, releases } from '@/lib/download';

export const dynamic = 'force-dynamic';

// GET /download (API.md): open to everyone, sign-in happens in the app. 302 to the latest DMG, or a coming-soon page.
export const GET = () => download(releases());
