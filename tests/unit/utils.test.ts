import { describe, expect, it } from 'vitest';
import { formatDuration, slugify } from '@/lib/utils';
describe('slugify', () => {
  it('removes straight and curly apostrophes without splitting the word', () => expect(slugify('Hurry Up, We’re Dreaming')).toBe('hurry-up-were-dreaming'));
  it('normalizes ampersands', () => expect(slugify('Rhythm & Noise')).toBe('rhythm-and-noise'));
});
describe('formatDuration', () => { it('formats milliseconds as minutes and seconds', () => expect(formatDuration(257000)).toBe('4:17')); });
