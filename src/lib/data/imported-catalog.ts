import type { Album, Artist, Song } from '@/lib/data/types';

export interface ImportedCatalogBundle {
  artists: Artist[];
  albums: Album[];
  songs: Song[];
}

export const emptyImportedCatalog = (): ImportedCatalogBundle => ({ artists: [], albums: [], songs: [] });

const importedArtists = new Map<string, Artist>();
const importedAlbums = new Map<string, Album>();
const importedSongs = new Map<string, Song>();

function absorb<T extends { id: string }>(target: Map<string, T>, incoming: T[]) {
  for (const item of incoming) target.set(item.id, item);
}

export function registerImportedCatalog(bundle: ImportedCatalogBundle | undefined | null) {
  if (!bundle) return;
  absorb(importedArtists, bundle.artists ?? []);
  absorb(importedAlbums, bundle.albums ?? []);
  absorb(importedSongs, bundle.songs ?? []);
}

export const importedCatalog = {
  artists: importedArtists,
  albums: importedAlbums,
  songs: importedSongs,
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
