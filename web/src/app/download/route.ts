import { auth } from '@/lib/auth';
import { installerOf, latestRelease } from '@/lib/download';

const COMING_SOON = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>shepetal for Mac is coming soon</title></head>
<body style="font-family:system-ui,sans-serif;max-width:32rem;margin:6rem auto;padding:0 1rem;line-height:1.5">
<h1>shepetal for Mac is coming soon</h1>
<p>The installer is not out yet. It will be here as soon as it is ready.</p>
<p><a href="/">Back to shepetal</a></p></body></html>`;

// GET /download (API.md): signed in only. 302 to /download/<installer> on this same domain, or a coming-soon page.
export async function GET(req: Request) {
  if (!(await auth())?.user?.email) {
    return Response.redirect(new URL('/api/auth/signin?callbackUrl=%2Fdownload', req.url), 302);
  }
  const installer = installerOf((await latestRelease()) ?? {});
  if (installer) return Response.redirect(new URL(`/download/${encodeURIComponent(installer.name)}`, req.url), 302);
  return new Response(COMING_SOON, { headers: { 'content-type': 'text/html; charset=utf-8' } });
}
