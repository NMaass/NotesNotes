import { describe, expect, it } from 'vitest';
import { albums, artists, genres, songs } from '@/lib/data/catalog';
import { dedupeAgainstSeed, matchScore, rankCatalog, type RankInput } from '@/lib/data/search-rank';
import { aliases, searchLocalCatalog } from '@/lib/data/selectors';
import type { Album, Artist } from '@/lib/data/types';

const seedRows: RankInput[] = [...artists, ...albums, ...songs, ...genres].map((entity) => ({ entity, aliases: aliases[entity.id], origin: 'seed' }));

describe('catalog search ranking', () => {
  it('scores exact, prefix, and contains on normalized text', () => {
    expect(matchScore('nirvana', ['Nirvana'])).toBe(100);
    expect(matchScore('nirv', ['Nirvana'])).toBe(70);
    expect(matchScore('rvan', ['Nirvana'])).toBe(40);
    // Like the web, apostrophes split words; the seed's aliases cover the contraction.
    expect(matchScore('Hurry up were', ['Hurry Up, We’re Dreaming'])).toBe(0);
    expect(matchScore('Hurry up were', ['Hurry Up, We’re Dreaming', 'hurry up were dreaming'])).toBe(70);
    expect(matchScore('zzz', ['Nirvana'])).toBe(0);
    expect(matchScore('!!!', ['Nirvana'])).toBe(0);
  });

  it('orders the seed exactly like the web search', () => {
    for (const query of ['mbv', 'li', 'night', 'the', 'pop']) {
      expect(rankCatalog(query, seedRows, 12).map((row) => row.entity.id), query).toEqual(searchLocalCatalog(query, 12).map((result) => result.entity.id));
    }
  });

  it('returns only the seed row when D1 holds the same MusicBrainz entity', () => {
    const nirvana = artists.find((artist) => artist.slug === 'nirvana')!;
    const duplicate: Artist = { ...nirvana, id: `mb-artist-${nirvana.musicbrainzId}` };
    const unrelated: Artist = { id: 'mb-artist-x', kind: 'artist', name: 'Nirvana (UK)', slug: 'nirvana-uk', musicbrainzId: 'x' };
    const ranked = rankCatalog('nirvana', [...seedRows, { entity: duplicate, origin: 'd1' }, { entity: unrelated, origin: 'd1' }], 10);
    expect(ranked.map((row) => row.entity.id)).toEqual([nirvana.id, 'mb-artist-x']);
  });

  it('drops a re-imported seeded song by its identity key (seeded songs have no recording id)', () => {
    const lithium = songs.find((song) => song.slug === 'lithium')!;
    const seedRow: RankInput = { entity: lithium, origin: 'seed', keys: ['song:5b11f4ce:lithium'] };
    const imported: RankInput = { entity: { ...lithium, id: 'mb-song-3fac712c', artistId: 'mb-artist-5b11f4ce', musicbrainzId: '3fac712c' }, origin: 'd1', keys: ['song:5b11f4ce:lithium'] };
    const cover: RankInput = { entity: { ...lithium, id: 'mb-song-other', artistId: 'mb-artist-x', musicbrainzId: 'other' }, origin: 'd1', keys: ['song:x:lithium'] };
    expect(rankCatalog('lithium', [seedRow, imported, cover], 10).map((row) => row.entity.id)).toEqual([lithium.id, 'mb-song-other']);
  });

  it('keeps D1 rows without a MusicBrainz id and drops repeated ids', () => {
    const local: Album = { id: 'd1-album', kind: 'album', name: 'Nevermind Demos', slug: 'nevermind-demos', artistId: 'a' };
    const rows = dedupeAgainstSeed([...seedRows, { entity: local, origin: 'd1' }, { entity: local, origin: 'd1' }]);
    expect(rows.filter((row) => row.entity.id === 'd1-album')).toHaveLength(1);
  });
});
