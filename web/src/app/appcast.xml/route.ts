import { appcast, releases } from '@/lib/download';

export const dynamic = 'force-dynamic';

// GET /appcast.xml (API.md): the Sparkle feed the Mac app checks (its SUFeedURL).
export const GET = (req: Request) => appcast(releases(), req);
