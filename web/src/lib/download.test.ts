import { expect, it, vi } from 'vitest';
import { assetResponse, installerOf, rewriteAppcast, servable } from './download';

const asset = (name: string, id = 1) => ({ id, name });

it('picks the Shepetal-<version>.dmg installer out of a release, else a .pkg', () => {
  expect(installerOf({ assets: [asset('notes.dmg'), asset('Shepetal-1.2.0.pkg'), asset('Shepetal-1.2.0.dmg')] })?.name).toBe('Shepetal-1.2.0.dmg');
  expect(installerOf({ assets: [asset('Shepetal-1.2.0.pkg')] })?.name).toBe('Shepetal-1.2.0.pkg');
  expect(installerOf({ assets: [asset('Shepetal-1.2.0.zip'), asset('Other-1.dmg')] })).toBeNull();
  expect(installerOf({})).toBeNull();
});

it('serves only the installer, its checksum and the appcast', () => {
  for (const ok of ['Shepetal-1.2.0.dmg', 'Shepetal-1.2.0.dmg.sha256', 'Shepetal-1.2.0.pkg', 'appcast.xml']) expect(servable(ok)).toBe(true);
  for (const no of ['../secrets', 'Shepetal-1.2.0.zip', 'source.tar.gz', 'Shepetal-1/../x.dmg']) expect(servable(no)).toBe(false);
});

// The repo goes private and customers must never see GitHub: every download URL in the appcast moves to our domain.
it('moves the appcast download URLs to the site, leaving the signatures alone', () => {
  const xml =
    '<enclosure url="https://github.com/backant-io/shepetal/releases/download/v1.2.0-mac/Shepetal-1.2.0.dmg" sparkle:edSignature="abc==" length="9"/>';
  const out = rewriteAppcast(xml, 'https://shepetal.app');
  expect(out).toBe('<enclosure url="https://shepetal.app/download/Shepetal-1.2.0.dmg" sparkle:edSignature="abc==" length="9"/>');
  expect(out).not.toMatch(/github/i);
});

it('streams an asset from the release through the site, never a redirect to GitHub', async () => {
  process.env.GITHUB_TOKEN = 'ghp_test';
  process.env.SHEPETAL_DOMAIN = 'shepetal.app';
  const calls: [string, RequestInit | undefined][] = [];
  const f = vi.fn<typeof fetch>(async (url, init) => {
    calls.push([String(url), init]);
    if (String(url).endsWith('/releases/latest')) return Response.json({ assets: [asset('Shepetal-1.2.0.dmg', 7), asset('appcast.xml', 8)] });
    if (String(url).endsWith('/assets/7')) return new Response('DMG', { headers: { 'content-length': '3' } });
    return new Response('<enclosure url="https://github.com/backant-io/shepetal/releases/download/v1/Shepetal-1.2.0.dmg"/>');
  });
  const dmg = (await assetResponse('Shepetal-1.2.0.dmg', f))!;
  expect(dmg.status).toBe(200);
  expect(await dmg.text()).toBe('DMG');
  expect(dmg.headers.get('content-disposition')).toBe('attachment; filename="Shepetal-1.2.0.dmg"');
  expect(dmg.headers.get('location')).toBeNull();
  expect((calls[1][1]?.headers as Record<string, string>).authorization).toBe('Bearer ghp_test');
  expect((calls[1][1]?.headers as Record<string, string>).accept).toBe('application/octet-stream');
  const feed = (await assetResponse('appcast.xml', f))!;
  expect(await feed.text()).toBe('<enclosure url="https://shepetal.app/download/Shepetal-1.2.0.dmg"/>');
  expect(await assetResponse('Shepetal-9.dmg', f)).toBeNull();
  expect(await assetResponse('../../etc/passwd', f)).toBeNull();
  delete process.env.GITHUB_TOKEN;
});
