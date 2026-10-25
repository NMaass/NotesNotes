import { describe, expect, it } from 'vitest';
import { seedDemoData } from '@/lib/data/catalog';
import { hasImportedRows, importedCatalog, registerImportedCatalog, withoutSeedRows } from '@/lib/data/imported-catalog';
import { artists as seedArtists, genres as seedGenres, songs as seedSongs } from '@/lib/data/catalog';
import { catalogLists, getEntity, getEntityById, getGenresForEntity, getGenreTagCount, getProfileEntityByPath } from '@/lib/data/selectors';
import type { Genre } from '@/lib/data/types';

// A MusicBrainz genre that exists only in D1, tagged from the phone, must render on the web.
const rock: Genre = { id: 'mb-genre-0e3fc579-2d24-4f20-9dae-736e1ec78798', kind: 'genre', name: 'Rock', slug: 'rock', musicbrainzId: '0e3fc579-2d24-4f20-9dae-736e1ec78798' };

describe('D1 genres on the web', () => {
  it('registers bundles that carry only genres', () => {
    expect(hasImportedRows({ artists: [], albums: [], songs: [], genres: [rock] })).toBe(true);
    expect(hasImportedRows({ artists: [], albums: [], songs: [] })).toBe(false);
  });

  it('resolves, lists, and counts an imported genre', () => {
    registerImportedCatalog({ artists: [], albums: [], songs: [], genres: [rock] });
    expect(getEntity('genre', rock.id)).toEqual(rock);
    expect(getEntityById(rock.id)).toEqual(rock);
    expect(catalogLists.genres.some((genre) => genre.id === rock.id)).toBe(true);
    expect(getProfileEntityByPath(['genre', 'rock'])).toEqual(rock);

    const data = JSON.parse(JSON.stringify(seedDemoData));
    data.genreAssertions.push({ id: 'g1', entityId: '40000000-0000-0000-0000-000000000001', entityKind: 'song', genreId: rock.id, source: 'user', createdBy: 'p1', votes: 1 });
    expect(getGenresForEntity('40000000-0000-0000-0000-000000000001', data).find((item) => item.genre.id === rock.id)).toMatchObject({ source: 'user', votes: 1 });
    expect(getGenreTagCount(rock.id, data)).toBe(1);
  });
});

describe('seed rows in server bundles', () => {
  it('registers only D1 rows; seeded rows already live in code', () => {
    const bundle = { artists: [seedArtists[0]], albums: [], songs: [seedSongs[0]], genres: [seedGenres[0]] };
    expect(withoutSeedRows(bundle)).toEqual({ artists: [], albums: [], songs: [], genres: [] });
    expect(hasImportedRows(bundle)).toBe(false);
    registerImportedCatalog(bundle);
    expect(importedCatalog.artists.has(seedArtists[0].id)).toBe(false);
    expect(catalogLists.genres.filter((genre) => genre.id === seedGenres[0].id)).toHaveLength(1);
  });
});
