import { describe, expect, it } from 'vitest';
import { same, seal, unseal } from './session';

// The web session and the OAuth cookie are only as good as this: nobody without AUTH_SECRET can make, read or change
// one, and one cookie's value never works as another's.
const SECRET = 'test-secret-0123456789abcdef';
const NOW = Date.parse('2026-10-22T12:00:00.000Z');

describe('sealed cookies', () => {
  it('give back what was sealed, until they expire', async () => {
    const v = await seal(SECRET, 'shepetal-session', { e: 'a@example.com' }, 60, NOW);
    expect(await unseal(SECRET, 'shepetal-session', v, NOW + 59_000)).toMatchObject({ e: 'a@example.com', exp: NOW + 60_000 });
    expect(await unseal(SECRET, 'shepetal-session', v, NOW + 60_000)).toBeNull();
  });

  it('are encrypted: the email is not readable in the cookie', async () => {
    const v = await seal(SECRET, 'shepetal-session', { e: 'a@example.com' }, 60, NOW);
    expect(atob(v.replace(/-/g, '+').replace(/_/g, '/'))).not.toContain('example');
  });

  it('refuse a forged, tampered, truncated or foreign value', async () => {
    const v = await seal(SECRET, 'shepetal-session', { e: 'a@example.com' }, 60, NOW);
    const flip = (s: string, i: number) => s.slice(0, i) + (s[i] === 'A' ? 'B' : 'A') + s.slice(i + 1);
    for (const bad of [flip(v, 5), flip(v, 20), flip(v, v.length - 2), v.slice(0, 30), '', 'x', `${v}x`, 'eyJlIjoiYUBleGFtcGxlLmNvbSJ9'])
      expect(await unseal(SECRET, 'shepetal-session', bad, NOW), bad).toBeNull();
    expect(await unseal('another-secret', 'shepetal-session', v, NOW)).toBeNull();
    // A value sealed for the OAuth cookie (or any other) is never a session.
    expect(await unseal(SECRET, 'shepetal-oauth', v, NOW)).toBeNull();
  });

  it('fail loud without AUTH_SECRET instead of using a fallback key', async () => {
    await expect(seal('', 'shepetal-session', {}, 60)).rejects.toThrow(/AUTH_SECRET/);
    await expect(unseal('', 'shepetal-session', 'x')).rejects.toThrow(/AUTH_SECRET/);
  });

  it('compare the state and the CSRF value whole', () => {
    expect(same('abc', 'abc')).toBe(true);
    for (const [a, b] of [['abc', 'abd'], ['abc', 'ab'], ['', 'a'], ['é', 'e']]) expect(same(a, b)).toBe(false);
  });
});
