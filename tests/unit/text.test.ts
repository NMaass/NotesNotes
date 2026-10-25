import { describe, expect, it } from 'vitest';
import {
  artistLikePattern,
  cleanTitle,
  fold,
  genreDisplayName,
  likePattern,
  matchKey,
  MAX_LIKE_PATTERN_BYTES,
  prefixLikePattern,
  primaryArtist,
  sameArtist,
  sameTitle,
  splitArtists,
  stableHash,
  strictLikePattern,
} from '@/lib/music/text';

describe('track text normalization (mirrors TrackText.swift)', () => {
  it('folds case, diacritics, ampersands, and punctuation', () => {
    expect(fold('Björk')).toBe('bjork');
    expect(fold('Simon & Garfunkel')).toBe('simon and garfunkel');
    expect(fold('Hurry Up, We’re Dreaming')).toBe('hurry up were dreaming');
    expect(fold('  AC/DC  ')).toBe('ac dc');
  });

  it('removes remaster and featured-artist noise but keeps version markers', () => {
    expect(cleanTitle('Lithium - Remastered 2011')).toBe('Lithium');
    expect(cleanTitle('Lithium (2011 Remaster)')).toBe('Lithium');
    expect(cleanTitle('Song [Deluxe Edition]')).toBe('Song');
    expect(cleanTitle('Song (feat. Someone)')).toBe('Song');
    expect(cleanTitle('Song - feat. Someone')).toBe('Song');
    expect(cleanTitle('Lithium (Live at Reading)')).toBe('Lithium (Live at Reading)');
    expect(cleanTitle('Lithium - Live')).toBe('Lithium - Live');
  });

  it('takes the primary artist', () => {
    expect(primaryArtist('Röyksopp feat. Susanne Sundfør')).toBe('Röyksopp');
    expect(primaryArtist('A, B & C')).toBe('A');
    expect(primaryArtist('Lil Nas X')).toBe('Lil Nas X');
    expect(primaryArtist('Artist x Other')).toBe('Artist');
    expect(splitArtists('Röyksopp feat. Susanne Sundfør')).toEqual(['Röyksopp', 'Susanne Sundfør']);
    expect(splitArtists('A, B & C')).toEqual(['A', 'B', 'C']);
  });

  it('builds the shared match key', () => {
    expect(matchKey('Nirvana', 'Lithium - Remastered 2011')).toBe('nirvana|lithium');
    expect(matchKey('Röyksopp feat. Susanne Sundfør', 'Some Resolve')).toBe('royksopp|some resolve');
  });

  it('compares artists and titles loosely enough for real sources', () => {
    expect(sameArtist('The Smashing Pumpkins', 'Smashing Pumpkins')).toBe(true);
    expect(sameArtist('Röyksopp', 'Royksopp')).toBe(true);
    expect(sameArtist('Nirvana', 'Nirvana (UK)')).toBe(false);
    expect(sameTitle('Lithium', 'lithium (2011 remaster)')).toBe(true);
    expect(sameTitle('Lithium', 'Lithium (Live)')).toBe(false);
    expect(sameTitle('', '')).toBe(false);
  });

  it('builds a LIKE prefilter that tolerates diacritics', () => {
    expect(likePattern('Björk')).toBe('%bj_rk%');
    expect(likePattern('sigur ros')).toBe('%s_g_r%r_s%');
    expect(likePattern('   ')).toBeNull();
    // Non-ASCII letters match any one character, so the stored spelling is found.
    expect(likePattern('Françoise Hardy')).toBe('%fr_n___s_%h_rd_%');
    expect(likePattern('Pisi Pisi Halayı')).toBe('%p_s_%p_s_%h_l___%');
  });

  it('keeps every LIKE pattern within D1’s 50-byte limit', () => {
    const bytes = (value: string | null) => new TextEncoder().encode(value ?? '').length;
    const classical = 'Symphony No. 9 in D Minor, Op. 125 "Choral": IV. Presto - Allegro assai ';
    const long = classical.repeat(3).slice(0, 200);
    for (const value of [long, classical.slice(0, 60), 'x'.repeat(300), 'Now That I’ve Found You (MTV unplugged live at Hull City Hall)', 'ä'.repeat(120)]) {
      expect(bytes(likePattern(value))).toBeLessThanOrEqual(MAX_LIKE_PATTERN_BYTES);
      expect(bytes(strictLikePattern(value))).toBeLessThanOrEqual(MAX_LIKE_PATTERN_BYTES);
      expect(bytes(prefixLikePattern(value))).toBeLessThanOrEqual(MAX_LIKE_PATTERN_BYTES);
      expect(bytes(artistLikePattern(value))).toBeLessThanOrEqual(MAX_LIKE_PATTERN_BYTES);
    }
    // Leading words are kept in order; a single over-long word is cut.
    expect(strictLikePattern(long)).toBe('%symphony%no%9%in%d%minor%op%125%choral%iv%presto%');
    expect(strictLikePattern('x'.repeat(300))).toBe(`%${'x'.repeat(48)}%`);
    // Multi-byte characters are never split.
    expect(prefixLikePattern('ä'.repeat(120))).toBe(`${'ä'.repeat(24)}%`);
  });

  it('builds prefix patterns only for queries without wildcards', () => {
    expect(prefixLikePattern(' Lith ')).toBe('Lith%');
    expect(prefixLikePattern('100%')).toBeNull();
    expect(prefixLikePattern('snake_case')).toBeNull();
    expect(prefixLikePattern('  ')).toBeNull();
  });

  it('narrows artists by the first word of the primary artist', () => {
    expect(artistLikePattern('The Beatles')).toBe('%b__tl_s%');
    expect(artistLikePattern('Nirvana feat. Nobody')).toBe('%n_rv_n_%');
    expect(artistLikePattern('Simon & Garfunkel')).toBe('%s_m_n%');
    expect(artistLikePattern('The The')).toBe('%th_%');
    expect(artistLikePattern('')).toBeNull();
    // Whatever sameArtist accepts still contains the pattern's word.
    for (const [track, stored] of [['The Beatles', 'Beatles'], ['Beatles', 'The Beatles'], ['Simon and Garfunkel', 'Simon & Garfunkel'], ['Björk', 'Björk']]) {
      expect(sameArtist(track, stored)).toBe(true);
      const word = artistLikePattern(track)!.slice(1, -1);
      expect(new RegExp(word.replace(/_/g, '.'), 'iu').test(stored)).toBe(true);
    }
  });

  it('hashes stably and formats genre names', () => {
    expect(stableHash('40000000-0000-0000-0000-000000000001')).toBe(stableHash('40000000-0000-0000-0000-000000000001'));
    expect(stableHash('a')).not.toBe(stableHash('b'));
    expect(genreDisplayName('baroque pop')).toBe('Baroque pop');
  });
});
