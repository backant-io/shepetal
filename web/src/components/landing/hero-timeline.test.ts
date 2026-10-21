import { describe, expect, it } from 'vitest';
import { onsets, plan, REVEAL_MAX, SCENES, WRITE_DELAY } from './hero-timeline';

const scenes = plan();

describe('hero demo timeline', () => {
  it('has the first line written in the email by 3.0 s, so a visitor sees the whole promise in the first three seconds', () => {
    expect(scenes[0].landEnd).toBeLessThanOrEqual(3000);
  });

  it('never lands text before the key comes up plus the paste, because the app writes on release and the demo must not promise more', () => {
    for (const s of scenes) for (const t of s.land) expect(t).toBeGreaterThanOrEqual(s.up + WRITE_DELAY);
  });

  it('finishes every line reveal in 560 ms or less, the brand limit for the word reveal', () => {
    for (const s of scenes) expect(s.landEnd - s.land[0]).toBeLessThanOrEqual(REVEAL_MAX);
  });

  it('speaks at a believable pace: each word after the one before, at least 150 ms apart, and the key up after the last', () => {
    for (const s of scenes) {
      const t = [s.down, ...s.said, s.up];
      for (let i = 1; i < t.length; i++) expect(t[i] - t[i - 1]).toBeGreaterThanOrEqual(150);
    }
  });

  it('gives a comma or a full stop a breath, so the speech has the rhythm of a sentence', () => {
    const { said } = onsets(['late,', 'start']);
    const { said: plain } = onsets(['late', 'start']);
    expect(said[1] - plain[1]).toBe(200);
  });

  it('plays the scenes back to back: each starts when the one before has finished, and every word has its times', () => {
    scenes.forEach((s, i) => {
      if (i) expect(s.from).toBe(scenes[i - 1].to);
      expect(s.said.length).toBe(SCENES[i].said.split(' ').length);
      expect(s.land.length).toBe(s.said.length);
      expect(s.to).toBeGreaterThanOrEqual(s.out);
    });
  });
});
