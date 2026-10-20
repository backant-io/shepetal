import { expect, it } from 'vitest';
import { installerOf } from './download';

const asset = (name: string) => ({ name, browser_download_url: `https://github.com/x/${name}` });

it('picks the Shepetal-*.pkg installer out of a release', () => {
  expect(installerOf({ assets: [asset('Shepetal-1.2.0.dmg'), asset('Shepetal-1.2.0.pkg'), asset('notes.pkg')] })).toBe(
    'https://github.com/x/Shepetal-1.2.0.pkg',
  );
  expect(installerOf({ assets: [asset('Shepetal-1.2.0.zip'), asset('Other-1.pkg')] })).toBeNull();
  expect(installerOf({})).toBeNull();
});
