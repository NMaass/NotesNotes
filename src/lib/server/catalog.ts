import 'server-only';
// Catalog reads for native clients: the code-seeded catalog and every D1 row,
// answered in one complete batch per request (see docs/IOS_API.md).
import {
  albums as seedAlbums,
  artists as seedArtists,
  catalog as seed,
  entityGenres as seedEntityGenres,
  genres as seedGenres,
  songCredits,
  songFacts,
  songs as seedSongs,
} from '@/lib/data/catalog';
import { matchScore, rankCatalog, type RankInput } from '@/lib/data/search-rank';
import { aliases as seedAliases } from '@/lib/data/selectors';
import type {
  Album,
  Artist,
  CatalogEntity,
  EntityKind,
  Genre,
  JournalEntry,
  MusicLens,
  Profile,
  RelationKind,
  SearchResult,
  Song,
  SongCredit,
  SongFact,
} from '@/lib/data/types';
import { all, allIn } from '@/lib/server/db';
import { encodeFeedCursor, type FeedCursor } from '@/lib/server/feed-cursor';
import {
  albumFromRow,
  artistFromRow,
  collectReferencedCatalog,
  genreFromRow,
  hydrateEntries,
  profileFromRow,
  songFromRow,
  type CatalogReference,
  type CatalogSlice,
} from '@/lib/server/repo';
import { fold, likePattern, normalizeSearch, prefixLikePattern, strictLikePattern } from '@/lib/music/text';

type Row = Record<string, unknown>;

export const ENTITY_KINDS: EntityKind[] = ['artist', 'album', 'song', 'genre'];

const TABLE: Record<EntityKind, 'artists' | 'albums' | 'songs' | 'genres'> = {
  artist: 'artists',
  album: 'albums',
  song: 'songs',
  genre: 'genres',
};

function fromRow(kind: EntityKind, row: Row): CatalogEntity {
  if (kind === 'artist') return artistFromRow(row);
  if (kind === 'album') return albumFromRow(row);
  if (kind === 'song') return songFromRow(row);
  return genreFromRow(row);
}

export function seedEntity(kind: EntityKind, id: string): CatalogEntity | undefined {
  if (kind === 'artist') return seed.artists.get(id);
  if (kind === 'album') return seed.albums.get(id);
  if (kind === 'song') return seed.songs.get(id);
  return seed.genres.get(id);
}

/** Seed and D1 entities of one kind by id, in two reads at most. */
export async function loadEntities<K extends EntityKind>(kind: K, ids: Iterable<string>): Promise<Map<string, Extract<CatalogEntity, { kind: K }>>> {
  type Entity = Extract<CatalogEntity, { kind: K }>;
  const found = new Map<string, Entity>();
  const missing: string[] = [];
  for (const id of new Set(ids)) {
    if (!id) continue;
    const local = seedEntity(kind, id);
    if (local) found.set(id, local as Entity);
    else missing.push(id);
  }
  const rows = await allIn<Row>((list) => `select * from ${TABLE[kind]} where id in (${list})`, missing);
  for (const row of rows) found.set(String(row.id), fromRow(kind, row) as Entity);
  return found;
}

export async function loadEntity(kind: EntityKind, id: string): Promise<CatalogEntity | undefined> {
  return (await loadEntities(kind, [id])).get(id);
}

// --- Subtitles (same wording as subtitleForEntity in selectors.ts) ---

function subtitleFor(entity: CatalogEntity, artists: Map<string, Artist>, albums: Map<string, Album>): string {
  if (entity.kind === 'artist') return [entity.country, 'Artist'].filter(Boolean).join(' · ');
  if (entity.kind === 'genre') return 'Genre';
  const artist = artists.get(entity.artistId);
  if (entity.kind === 'album') return [artist?.name, entity.year].filter(Boolean).join(' · ');
  const album = entity.albumId ? albums.get(entity.albumId) : undefined;
  return [artist?.name, album?.name].filter(Boolean).join(' · ');
}

// --- Search ---

/** The artist's MusicBrainz id when known (seeded artists carry one; imports encode it in their id). */
function artistIdentity(artistId: string): string {
  if (artistId.startsWith('mb-artist-')) return artistId.slice('mb-artist-'.length);
  return seed.artists.get(artistId)?.musicbrainzId ?? artistId;
}

/** Identities shared by a seeded row and its imported duplicate (seeded songs carry no recording id). */
function identityKeys(entity: CatalogEntity): string[] {
  if (entity.kind === 'song' || entity.kind === 'album') return [`${entity.kind}:${artistIdentity(entity.artistId)}:${fold(entity.name)}`];
  if (entity.kind === 'genre') return [`genre:${fold(entity.name)}`];
  return [];
}

const SEARCH_TABLES = ['artists', 'albums', 'songs', 'genres'] as const;
const SEARCH_ROWS_PER_TABLE = 200;

function d1SearchRows(table: typeof SEARCH_TABLES[number], rows: Row[]): RankInput[] {
  if (table === 'artists') return rows.map((row) => ({ entity: artistFromRow(row), origin: 'd1' as const }));
  const entities: CatalogEntity[] = rows.map((row) => (table === 'albums' ? albumFromRow(row) : table === 'songs' ? songFromRow(row) : genreFromRow(row)));
  return entities.map((entity) => ({ entity, origin: 'd1' as const, keys: identityKeys(entity) }));
}

/**
 * Seed catalog plus every D1 artist/album/song/genre, ranked as one batch.
 *
 * D1 is read in up to two passes. The first finds names that start with the
 * query through the NOCASE name indexes (rows read ≈ rows matched). Only when
 * that leaves fewer than `limit` results scoring "prefix" or better does the
 * second pass scan for names that contain the query anywhere (bounded loose
 * LIKE patterns, then the same JS ranking): contains-matches rank below prefix
 * matches, so they could not have made the page otherwise.
 */
export async function searchCatalog(query: string, limit: number): Promise<SearchResult[]> {
  const normalized = normalizeSearch(query);
  if (!normalized) return [];
  const seedRows: RankInput[] = [...seedArtists, ...seedAlbums, ...seedSongs, ...seedGenres]
    .map((entity) => ({ entity, aliases: seedAliases[entity.id], origin: 'seed' as const, keys: identityKeys(entity) }));

  let d1Rows: RankInput[] = [];
  const prefix = prefixLikePattern(query);
  if (prefix) {
    const tables = await Promise.all(SEARCH_TABLES.map((table) => all<Row>(
      `select * from ${table} where name like ? order by length(name) limit ${SEARCH_ROWS_PER_TABLE}`,
      prefix,
    )));
    d1Rows = SEARCH_TABLES.flatMap((table, index) => d1SearchRows(table, tables[index]));
  }
  const strongEnough = rankCatalog(query, [...seedRows, ...d1Rows], limit)
    .filter((row) => matchScore(query, [row.entity.name, ...(row.aliases ?? [])]) >= 70);
  if (!prefix || strongEnough.length < limit) {
    // Every pattern stays within D1's 50-byte LIKE limit; the loose one lets "bjork" reach "Björk".
    const strict = strictLikePattern(query) ?? '%';
    const loose = likePattern(query) ?? strict;
    const tables = await Promise.all(SEARCH_TABLES.map((table) => all<Row>(
      `select * from ${table} where name like ?1 or name like ?2 order by (name like ?1) desc, length(name) limit ${SEARCH_ROWS_PER_TABLE}`,
      strict, loose,
    )));
    d1Rows = [...d1Rows, ...SEARCH_TABLES.flatMap((table, index) => d1SearchRows(table, tables[index]))];
  }
  const ranked = rankCatalog(query, [...seedRows, ...d1Rows], limit);

  // Parents for subtitles, fetched once for the whole batch.
  const albumIds = ranked.flatMap(({ entity }) => (entity.kind === 'song' && entity.albumId ? [entity.albumId] : []));
  const albums = await loadEntities('album', albumIds);
  const artistIds = [
    ...ranked.flatMap(({ entity }) => (entity.kind === 'album' || entity.kind === 'song' ? [entity.artistId] : [])),
    ...[...albums.values()].map((album) => album.artistId),
  ];
  const artists = await loadEntities('artist', artistIds);
  return ranked.map(({ entity }) => ({ entity, subtitle: subtitleFor(entity, artists, albums), source: 'local' }));
}

// --- Genres ---

export async function listGenres(): Promise<Genre[]> {
  const rows = await all<Row>('select * from genres order by name collate nocase');
  return [...seedGenres, ...rows.map(genreFromRow)];
}

export interface GenreTagCount { genre: Genre; source: 'catalog' | 'community' | 'user'; votes: number; mine?: boolean }

type GenreRow = { entityId: string; genreId: string; source: 'catalog' | 'community' | 'user'; votes?: number; createdBy?: string };

/** Mirrors getGenresForEntity: catalog/community rows bring their votes, each listener tag counts one. */
export function combineGenreRows(rows: GenreRow[], genres: Map<string, Genre>, viewer: string | null): GenreTagCount[] {
  const grouped = new Map<string, GenreTagCount>();
  for (const row of rows) {
    const genre = genres.get(row.genreId);
    if (!genre) continue;
    const current = grouped.get(row.genreId);
    const source = current?.source === 'community' || row.source === 'community'
      ? 'community'
      : current?.source === 'user' || row.source === 'user' ? 'user' : 'catalog';
    const votes = (current?.votes ?? 0) + (row.source === 'user' ? 1 : (row.votes ?? 0));
    const next: GenreTagCount = { genre, source, votes };
    if (viewer) next.mine = Boolean(current?.mine) || (row.source === 'user' && row.createdBy === viewer);
    grouped.set(row.genreId, next);
  }
  return [...grouped.values()].sort((a, b) => b.votes - a.votes || a.genre.name.localeCompare(b.genre.name));
}

function d1GenreRow(row: Row): GenreRow {
  const source = row.source === 'community' || row.source === 'user' ? row.source : 'catalog';
  return {
    entityId: String(row.entity_id),
    genreId: String(row.genre_id),
    source,
    votes: typeof row.votes === 'number' ? row.votes : Number(row.votes ?? 0) || 0,
    createdBy: typeof row.created_by === 'string' ? row.created_by : undefined,
  };
}

/** Combined genre tags for several entities, keyed by entity id. */
export async function genresForEntities(entityIds: string[], viewer: string | null): Promise<Map<string, GenreTagCount[]>> {
  const ids = new Set(entityIds.filter(Boolean));
  const d1Rows = (await allIn<Row>((list) => `select * from entity_genres where entity_id in (${list})`, ids)).map(d1GenreRow);
  const rows: GenreRow[] = [
    ...seedEntityGenres.filter((row) => ids.has(row.entityId)).map((row) => ({ entityId: row.entityId, genreId: row.genreId, source: row.source, votes: row.votes, createdBy: row.createdBy })),
    ...d1Rows,
  ];
  const genres = await loadEntities('genre', rows.map((row) => row.genreId));
  const result = new Map<string, GenreTagCount[]>();
  for (const id of ids) result.set(id, combineGenreRows(rows.filter((row) => row.entityId === id), genres, viewer));
  return result;
}

// --- Entity detail ---

export interface Connection { entity: CatalogEntity; count: number; lenses: MusicLens[]; relations: RelationKind[] }

export interface EntityDetail {
  ok: true;
  entity: CatalogEntity;
  artist?: Artist;
  album?: Album;
  albums: Album[];
  tracks: Song[];
  genres: GenreTagCount[];
  credits: SongCredit[];
  facts: SongFact[];
  entries: JournalEntry[];
  authors: Profile[];
  connections: Connection[];
  catalog: CatalogSlice;
  /** Genre entities only: every tag on it, counted as the web's getGenreTagCount does. */
  tagCount?: number;
}

const MAX_ENTRIES = 50;
const MAX_TRACKS = 200;

function byTrackNumber(a: Song, b: Song) {
  return (a.trackNumber ?? 9999) - (b.trackNumber ?? 9999) || a.name.localeCompare(b.name);
}

/** Seed rows first; a D1 row is dropped when a seed row already has its MusicBrainz id or (songs) its title. */
function mergeSeedFirst<T extends Album | Song>(seeded: T[], stored: T[]): T[] {
  const mbids = new Set(seeded.map((item) => item.musicbrainzId).filter(Boolean));
  const names = new Set(seeded.map((item) => `${item.kind}:${fold(item.name)}`));
  const ids = new Set(seeded.map((item) => item.id));
  return [
    ...seeded,
    ...stored.filter((item) => !ids.has(item.id) && !(item.musicbrainzId && mbids.has(item.musicbrainzId)) && !names.has(`${item.kind}:${fold(item.name)}`)),
  ];
}

/** Artist ids that describe the same artist: a seeded artist and its imported duplicate. */
function artistAliases(artist: Artist): string[] {
  return artist.musicbrainzId && !artist.id.startsWith('mb-artist-') ? [artist.id, `mb-artist-${artist.musicbrainzId}`] : [artist.id];
}

async function albumsByArtist(artist: Artist): Promise<Album[]> {
  const ids = artistAliases(artist);
  const rows = await allIn<Row>((list) => `select * from albums where artist_id in (${list}) order by release_year`, ids);
  const seeded = seedAlbums.filter((album) => ids.includes(album.artistId));
  return mergeSeedFirst(seeded, rows.map(albumFromRow)).sort((a, b) => (a.year ?? 9999) - (b.year ?? 9999) || a.name.localeCompare(b.name));
}

async function tracksForAlbum(album: Album): Promise<Song[]> {
  // A seeded album with a MusicBrainz id may also have been imported in full; merge its tracklist.
  const ids = album.musicbrainzId && !album.id.startsWith('mb-album-') ? [album.id, `mb-album-${album.musicbrainzId}`] : [album.id];
  const rows = await allIn<Row>((list) => `select * from songs where album_id in (${list})`, ids);
  const seeded = seedSongs.filter((song) => song.albumId === album.id);
  // Imports of different pressings can add the same track twice (another recording); show it once.
  const seen = new Set<string>();
  return mergeSeedFirst(seeded, rows.map(songFromRow))
    .sort(byTrackNumber)
    .filter((song) => {
      const key = `${song.trackNumber ?? ''}:${fold(song.name)}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .slice(0, MAX_TRACKS);
}

async function tracksForArtist(artist: Artist): Promise<Song[]> {
  const ids = artistAliases(artist);
  const rows = await allIn<Row>((list) => `select * from songs where artist_id in (${list}) limit ${MAX_TRACKS}`, ids);
  const seeded = seedSongs.filter((song) => ids.includes(song.artistId));
  return mergeSeedFirst(seeded, rows.map(songFromRow)).slice(0, MAX_TRACKS);
}

async function taggedWithGenre(genreId: string): Promise<{ albums: Album[]; tracks: Song[] }> {
  const rows = await all<Row>('select entity_id, entity_kind from entity_genres where genre_id = ? limit 500', genreId);
  const links = [
    ...seedEntityGenres.filter((row) => row.genreId === genreId).map((row) => ({ id: row.entityId, kind: row.entityKind })),
    ...rows.map((row) => ({ id: String(row.entity_id), kind: row.entity_kind as EntityKind | undefined })),
  ];
  const ids = links.map((link) => link.id);
  const [albums, songs] = await Promise.all([loadEntities('album', ids), loadEntities('song', ids)]);
  return { albums: [...albums.values()].slice(0, MAX_ENTRIES), tracks: [...songs.values()].slice(0, MAX_ENTRIES) };
}

/**
 * How many times anyone tagged a genre, as the web's genre page counts it
 * (getGenreTagCount): a listener's tag counts one, a catalog or community row
 * its votes (one when it has none).
 */
export async function genreTagCount(genreId: string): Promise<number> {
  const seeded = seedEntityGenres
    .filter((row) => row.genreId === genreId)
    .reduce((sum, row) => sum + (row.source === 'user' ? 1 : (row.votes ?? 1)), 0);
  const stored = await all<{ n: number | null }>(
    "select sum(case when source = 'user' then 1 else coalesce(votes, 1) end) as n from entity_genres where genre_id = ?",
    genreId,
  );
  return seeded + Number(stored[0]?.n ?? 0);
}

/** Public entries about entity ids, newest first. */
async function publicEntriesAbout(entityId: string): Promise<JournalEntry[]> {
  const rows = await all<Row>(
    `select * from journal_entries where entity_id = ? and is_public = 1 order by updated_at desc limit ${MAX_ENTRIES}`,
    entityId,
  );
  return hydrateEntries(rows);
}

export async function loadProfiles(ids: Iterable<string>): Promise<Profile[]> {
  const rows = await allIn<Row>((list) => `select * from profiles where id in (${list})`, ids);
  return rows.map(profileFromRow);
}

/** Everything one entity screen needs. Null when the id is unknown for that kind. */
export async function loadEntityDetail(kind: EntityKind, id: string, viewer: string | null): Promise<EntityDetail | null> {
  const entity = await loadEntity(kind, id);
  if (!entity) return null;

  let artist: Artist | undefined;
  let album: Album | undefined;
  if (entity.kind === 'album' || entity.kind === 'song') artist = await loadEntity('artist', entity.artistId) as Artist | undefined;
  if (entity.kind === 'song' && entity.albumId) album = await loadEntity('album', entity.albumId) as Album | undefined;

  const relatedAlbums = async (): Promise<Album[]> => {
    if (entity.kind === 'artist') return albumsByArtist(entity);
    if (entity.kind === 'album' && artist) {
      // The artist's other albums: not this one, nor its imported duplicate.
      return (await albumsByArtist(artist)).filter((item) => item.id !== entity.id && !(entity.musicbrainzId && item.musicbrainzId === entity.musicbrainzId));
    }
    return [];
  };
  const relatedTracks = async (): Promise<Song[]> => {
    if (entity.kind === 'album') return tracksForAlbum(entity);
    if (entity.kind === 'song' && album) return tracksForAlbum(album);
    if (entity.kind === 'artist') return tracksForArtist(entity);
    return [];
  };
  const [albumList, trackList, tagged, genreMap, entries, tagCount] = await Promise.all([
    relatedAlbums(),
    relatedTracks(),
    entity.kind === 'genre' ? taggedWithGenre(entity.id) : Promise.resolve(null),
    entity.kind === 'genre' ? Promise.resolve(new Map<string, GenreTagCount[]>()) : genresForEntities([entity.id], viewer),
    publicEntriesAbout(entity.id),
    entity.kind === 'genre' ? genreTagCount(entity.id) : Promise.resolve(undefined),
  ]);
  const albums = tagged ? tagged.albums : albumList;
  const tracks = tagged ? tagged.tracks : trackList;

  const references: CatalogReference[] = entries.flatMap((entry) => [
    { kind: entry.entityKind, id: entry.entityId },
    ...entry.references.map((reference) => ({ kind: reference.entityKind as EntityKind, id: reference.entityId })),
  ]);
  const [authors, catalog] = await Promise.all([
    loadProfiles(entries.map((entry) => entry.profileId)),
    collectReferencedCatalog(references),
  ]);

  // Connections come only from references writers placed in their own entries.
  const known = new Map<string, CatalogEntity>();
  for (const item of [...catalog.artists, ...catalog.albums, ...catalog.songs, ...(catalog.genres ?? [])]) known.set(item.id, item);
  const connections = new Map<string, { entity: CatalogEntity; count: number; lenses: Set<MusicLens>; relations: Set<RelationKind> }>();
  for (const entry of entries) {
    for (const reference of entry.references) {
      const target = seedEntity(reference.entityKind, reference.entityId) ?? known.get(reference.entityId);
      if (!target) continue;
      const current = connections.get(target.id) ?? { entity: target, count: 0, lenses: new Set<MusicLens>(), relations: new Set<RelationKind>() };
      current.count += 1;
      reference.lenses.forEach((lens) => current.lenses.add(lens));
      current.relations.add(reference.relation);
      connections.set(target.id, current);
    }
  }

  return {
    ok: true,
    entity,
    ...(artist ? { artist } : {}),
    ...(album ? { album } : {}),
    albums,
    tracks,
    genres: genreMap.get(entity.id) ?? [],
    credits: entity.kind === 'song' ? songCredits.filter((credit) => credit.songId === entity.id) : [],
    facts: entity.kind === 'song' ? songFacts.filter((fact) => fact.songId === entity.id) : [],
    entries,
    authors,
    connections: [...connections.values()]
      .map((item) => ({ entity: item.entity, count: item.count, lenses: [...item.lenses], relations: [...item.relations] }))
      .sort((a, b) => b.count - a.count || a.entity.name.localeCompare(b.entity.name)),
    catalog,
    ...(tagCount === undefined ? {} : { tagCount }),
  };
}

// --- Feed ---

export interface FeedPage {
  ok: true;
  entries: JournalEntry[];
  profiles: Profile[];
  catalog: CatalogSlice;
  nextCursor?: string;
}

/**
 * Public entries across everyone, newest first by updated_at then id, so
 * entries sharing a timestamp are neither skipped nor repeated between pages.
 * Seeded demo entries are demo-only and never appear.
 */
export async function loadFeed(limit: number, before: FeedCursor | null): Promise<FeedPage> {
  const rows = before?.id
    ? await all<Row>(
      'select * from journal_entries where is_public = 1 and (updated_at < ?1 or (updated_at = ?1 and id < ?2)) order by updated_at desc, id desc limit ?3',
      before.updatedAt, before.id, limit,
    )
    : before
      ? await all<Row>('select * from journal_entries where is_public = 1 and updated_at < ? order by updated_at desc, id desc limit ?', before.updatedAt, limit)
      : await all<Row>('select * from journal_entries where is_public = 1 order by updated_at desc, id desc limit ?', limit);
  const entries = await hydrateEntries(rows);
  const [profiles, catalog] = await Promise.all([
    loadProfiles(entries.map((entry) => entry.profileId)),
    collectReferencedCatalog(entries.flatMap((entry) => [
      { kind: entry.entityKind, id: entry.entityId },
      ...entry.references.map((reference) => ({ kind: reference.entityKind as EntityKind, id: reference.entityId })),
    ])),
  ]);
  const page: FeedPage = { ok: true, entries, profiles, catalog };
  const last = rows[rows.length - 1];
  if (entries.length === limit && last) page.nextCursor = encodeFeedCursor({ updatedAt: String(last.updated_at), id: String(last.id) });
  return page;
}
