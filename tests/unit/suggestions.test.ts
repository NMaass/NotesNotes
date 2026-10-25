import { describe, expect, it } from 'vitest';
import { MOODS, orderGenreSuggestions, pickPrompt, PROMPTS, rankLenses, rankMoods } from '@/lib/music/suggestions';

describe('genre suggestions', () => {
  it('orders song, album, then artist tags by votes, then MusicBrainz, de-duplicated, four at most', () => {
    const grunge = { id: 'grunge', name: 'Grunge', source: 'community', votes: 96 };
    const result = orderGenreSuggestions(
      [
        [{ id: 'alt', name: 'Alternative rock', source: 'user', votes: 1 }, grunge],
        [{ ...grunge, votes: 182 }],
        [{ id: 'grunge', name: 'Grunge', source: 'catalog', votes: 0 }],
      ],
      [
        { id: 'mb-rock', name: 'Rock', source: 'musicbrainz', votes: 14 },
        { id: 'alt', name: 'Alternative rock', source: 'musicbrainz', votes: 9 },
        { id: 'mb-punk', name: 'Punk', source: 'musicbrainz', votes: 3 },
        { id: 'mb-pop', name: 'Pop', source: 'musicbrainz', votes: 1 },
      ],
    );
    expect(result).toEqual([
      { id: 'grunge', name: 'Grunge', source: 'community' },
      { id: 'alt', name: 'Alternative rock', source: 'user' },
      { id: 'mb-rock', name: 'Rock', source: 'musicbrainz' },
      { id: 'mb-punk', name: 'Punk', source: 'musicbrainz' },
    ]);
  });
});

describe('lens suggestions', () => {
  it('ranks by how many public entries use a lens and pads with the default order', () => {
    expect(rankLenses([['performance', 'production'], ['performance'], ['bogus']])).toEqual(['performance', 'production', 'feeling', 'lyrics']);
    expect(rankLenses([])).toEqual(['feeling', 'production', 'lyrics', 'context']);
  });
});

describe('mood suggestions', () => {
  it('weights this song’s listens, keeps custom moods, and pads with the standard list', () => {
    const moods = rankMoods([
      { songId: 'other', moods: ['focused', 'focused'] },
      { songId: 'other', moods: ['warm'] },
      { songId: 'other', moods: ['warm'] },
      { songId: 'this', moods: ['nostalgic', 'Rainy'] },
    ], 'this');
    expect(moods.slice(0, 4)).toEqual(['nostalgic', 'rainy', 'warm', 'focused']);
    expect(moods).toHaveLength(MOODS.length);
    expect(rankMoods([], undefined)).toEqual([...MOODS]);
  });
});

describe('prompts', () => {
  it('asks returning writers and listeners specific questions, others a stable pick', () => {
    expect(pickPrompt({ wroteBefore: true, listenedBefore: true, seed: 'x' })).toBe('What did you notice this time?');
    expect(pickPrompt({ wroteBefore: false, listenedBefore: true, seed: 'x' })).toBe('What does this take you back to?');
    const first = pickPrompt({ wroteBefore: false, listenedBefore: false, seed: 'song-1' });
    expect(pickPrompt({ wroteBefore: false, listenedBefore: false, seed: 'song-1' })).toBe(first);
    expect(PROMPTS.slice(2)).toContain(first);
  });
});
