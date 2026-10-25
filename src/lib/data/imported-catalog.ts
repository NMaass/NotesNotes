import { catalog as seedCatalog } from '@/lib/data/catalog';
import type { Album, Artist, Genre, Song } from '@/lib/data/types';

export interface ImportedCatalogBundle {
  artists: Artist[];
  albums: Album[];
  songs: Song[];
  /** Genres the payload references (seeded ones are skipped here; see withoutSeedRows). */
  genres?: Genre[];
}

/**
 * Server bundles also carry seeded rows (the native app has no copy of the seed
 * catalog). The web already has them in code, so only rows from D1 are registered.
 */
export function withoutSeedRows(bundle: ImportedCatalogBundle): ImportedCatalogBundle {
  return {
    artists: (bundle.artists ?? []).filter((item) => !seedCatalog.artists.has(item.id)),
    albums: (bundle.albums ?? []).filter((item) => !seedCatalog.albums.has(item.id)),
    songs: (bundle.songs ?? []).filter((item) => !seedCatalog.songs.has(item.id)),
    genres: (bundle.genres ?? []).filter((item) => !seedCatalog.genres.has(item.id)),
  };
}

export const emptyImportedCatalog = (): ImportedCatalogBundle => ({ artists: [], albums: [], songs: [], genres: [] });

const importedArtists = new Map<string, Artist>();
const importedAlbums = new Map<string, Album>();
const importedSongs = new Map<string, Song>();
const importedGenres = new Map<string, Genre>();

function absorb<T extends { id: string }>(target: Map<string, T>, incoming: T[]) {
  for (const item of incoming) target.set(item.id, item);
}

export function registerImportedCatalog(bundle: ImportedCatalogBundle | undefined | null) {
  if (!bundle) return;
  const imported = withoutSeedRows(bundle);
  absorb(importedArtists, imported.artists);
  absorb(importedAlbums, imported.albums);
  absorb(importedSongs, imported.songs);
  absorb(importedGenres, imported.genres ?? []);
}

/** Whether a bundle carries any non-seed catalog rows worth registering. */
export function hasImportedRows(bundle: ImportedCatalogBundle | undefined | null): boolean {
  if (!bundle) return false;
  const imported = withoutSeedRows(bundle);
  return Boolean(imported.artists.length || imported.albums.length || imported.songs.length || imported.genres?.length);
}

export const importedCatalog = {
  artists: importedArtists,
  albums: importedAlbums,
  songs: importedSongs,
  genres: importedGenres,
};

export function importedArtistList(): Artist[] {
  return [...importedArtists.values()];
}

export function importedAlbumList(): Album[] {
  return [...importedAlbums.values()];
}

export function importedSongList(): Song[] {
  return [...importedSongs.values()];
}

export function importedGenreList(): Genre[] {
  return [...importedGenres.values()];
}
