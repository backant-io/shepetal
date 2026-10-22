import { track, visitorId } from '@/lib/analytics';
import { appcast, releases } from '@/lib/download';

export const dynamic = 'force-dynamic';

/** The app's version from Sparkle's user agent ("shepetal/0.3.0 Sparkle/2.6.4"). */
const appVersion = (ua: string | null) => ua?.match(/^shepetal\/([\w.+-]{1,32})/i)?.[1];

// GET /appcast.xml (API.md): the Sparkle feed the Mac app checks (its SUFeedURL). Each check counts as active
// (appcast_check), with the app's version.
export async function GET(req: Request) {
  await track('appcast_check', visitorId(req), { app_version: appVersion(req.headers.get('user-agent')) });
  return appcast(releases(), req);
}
