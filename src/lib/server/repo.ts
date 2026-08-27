import 'server-only';
import { randomUUID } from 'node:crypto';
import { all, first, run } from '@/lib/server/db';
import type {
  Album,
  Artist,
  Collection,
  EntityGenre,
  EntityKind,
  JournalEntry,
  Like,
  ListenLog,
  MusicLens,
  MusicReference,
  Profile,
  ProfilePin,
  ProfileBundle,
  RelationKind,
  RichDocument,
  Song,
} from '@/lib/data/types';

type Row = Record<string, unknown>;

export interface CatalogSlice {
  artists: Artist[];
  albums: Album[];
  songs: Song[];
}

const KINDS: EntityKind[] = ['artist', 'album', 'song', 'genre'];
const LENSES: MusicLens[] = ['feeling', 'lyrics', 'composition', 'performance', 'production', 'context'];
const RELATIONS: RelationKind[] = ['reminds-me-of', 'influenced-by', 'pairs-with', 'contrasts-with', 'mentions'];

function str(value: unknown): string {
  return String(value ?? '');
}

function optStr(value: unknown): string | undefined {
  return typeof value === 'string' && value.length ? value : undefined;
}

function num(value: unknown): number | undefined {
  const parsed = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function json<T>(value: unknown, fallback: T): T {
  if (typeof value !== 'string' || !value.length) return fallback;
  try {
    return JSON.parse(value) as T;
  } catch {
    return fallback;
  }
}

function asKind(value: unknown): EntityKind {
  return KINDS.includes(value as EntityKind) ? value as EntityKind : 'song';
}

function asLenses(value: unknown): MusicLens[] {
  return json<unknown[]>(value, []).filter((lens): lens is MusicLens => LENSES.includes(lens as MusicLens));
}

function asRelation(value: unknown): RelationKind {
  return RELATIONS.includes(value as RelationKind) ? value as RelationKind : 'mentions';
}

// --- Row mappers (shapes mirror the previous Postgres adapter exactly) ---

function profileFromRow(row: Row): Profile {
  return {
    id: str(row.id),
    handle: str(row.handle),
    displayName: str(row.display_name),
    bio: str(row.bio),
    avatarUrl: optStr(row.avatar_url),
    profileSongId: optStr(row.profile_song_id),
    genreIds: json<string[]>(row.genre_ids, []),
  };
}

function likeFromRow(row: Row): Like {
  return {
    id: str(row.id),
    profileId: str(row.profile_id),
    entityId: str(row.entity_id),
    entityKind: asKind(row.entity_kind),
    clientVersion: num(row.client_version) ?? 1,
    createdAt: str(row.created_at),
  };
}

function referenceFromRow(row: Row): MusicReference {
  return {
    id: str(row.reference_id),
    entityId: str(row.entity_id),
    entityKind: asKind(row.entity_kind),
    label: str(row.label),
    relation: asRelation(row.relation),
    lenses: asLenses(row.lenses),
  };
}

function entryFromRow(row: Row, references: MusicReference[]): JournalEntry {
  return {
    id: str(row.id),
    profileId: str(row.profile_id),
    entityId: str(row.entity_id),
    entityKind: asKind(row.entity_kind),
    title: optStr(row.title),
    document: json<RichDocument>(row.document, { type: 'doc', content: [] }),
    plainText: str(row.plain_text),
    worked: optStr(row.worked),
    didntWork: optStr(row.didnt_work),
    lenses: asLenses(row.lenses),
    references,
    public: Boolean(row.is_public),
    createdAt: str(row.created_at),
    updatedAt: str(row.updated_at),
  };
}

function listenFromRow(row: Row): ListenLog {
  return {
    id: str(row.id),
    profileId: str(row.profile_id),
    songId: str(row.song_id),
    moods: json<string[]>(row.moods, []),
    note: optStr(row.note),
    listenedAt: str(row.listened_at),
  };
}

function pinFromRow(row: Row): ProfilePin {
  const targetType = row.target_type;
  if (targetType !== 'entity' && targetType !== 'entry' && targetType !== 'collection') {
    throw new Error(`Unknown pin target: ${String(targetType)}`);
  }
  return {
    id: str(row.id),
    profileId: str(row.profile_id),
    targetType,
    targetId: str(row.target_id),
    position: num(row.position) ?? 0,
  };
}

function assertionFromRow(row: Row): EntityGenre {
  return {
    id: str(row.id),
    entityId: str(row.entity_id),
    entityKind: asKind(row.entity_kind),
    genreId: str(row.genre_id),
    source: 'user',
    createdBy: optStr(row.created_by),
    votes: num(row.votes) ?? 1,
  };
}

// --- Bundles ---

async function loadEntriesFor(profileId: string, includePrivate: boolean): Promise<JournalEntry[]> {
  const rows = await all<Row>(
    includePrivate
      ? 'select * from journal_entries where profile_id = ? order by updated_at desc'
      : 'select * from journal_entries where profile_id = ? and is_public = 1 order by updated_at desc',
    profileId,
  );
  if (!rows.length) return [];
  const references = await all<Row>(
    `select * from entry_references where entry_id in (${rows.map(() => '?').join(',')})`,
    ...rows.map((row) => str(row.id)),
  );
  const grouped = new Map<string, MusicReference[]>();
  for (const row of references) {
    const entryId = str(row.entry_id);
    const list = grouped.get(entryId) ?? [];
    list.push(referenceFromRow(row));
    grouped.set(entryId, list);
  }
  return rows.map((row) => entryFromRow(row, grouped.get(str(row.id)) ?? []));
}

export interface OwnBundle extends ProfileBundle { catalog: CatalogSlice }

/** The signed-in person's complete view, including their private listening log. */
export async function loadOwnBundle(userId: string): Promise<OwnBundle> {
  const profileRow = await first<Row>('select * from profiles where id = ?', userId);
  if (!profileRow) throw new Error('Profile not found.');
  const profile = profileFromRow(profileRow);

  const [likes, entries, listens, collections, pins, assertions] = await Promise.all([
    all<Row>('select * from likes where profile_id = ? order by created_at asc', userId),
    loadEntriesFor(userId, true),
    all<Row>('select * from listen_logs where profile_id = ? order by listened_at desc', userId),
    all<Row>('select * from collections where profile_id = ? order by created_at asc', userId),
    all<Row>('select * from profile_pins where profile_id = ?', userId),
    all<Row>("select * from entity_genres where source = 'user' and created_by = ?", userId),
  ]);

  const collectionIds = collections.map((collection) => str(collection.id));
  const items = collectionIds.length
    ? await all<Row>(
        `select * from collection_items where collection_id in (${collectionIds.map(() => '?').join(',')}) order by position asc`,
        ...collectionIds,
      )
    : [];

  const catalog = await collectReferencedCatalog([
    ...likes.map((row) => ({ kind: asKind(row.entity_kind), id: str(row.entity_id) })),
    ...entries.flatMap((entry) => [
      { kind: entry.entityKind, id: entry.entityId },
      ...entry.references.map((reference) => ({ kind: reference.entityKind as EntityKind, id: reference.entityId })),
    ]),
    ...items.map((row) => ({ kind: asKind(row.entity_kind), id: str(row.entity_id) })),
    ...(profile.profileSongId ? [{ kind: 'song' as EntityKind, id: profile.profileSongId }] : []),
  ]);

  return {
    profile,
    likes: likes.map(likeFromRow),
    entries,
    listens: listens.map(listenFromRow),
    collections: collections.map((row) => ({
      id: str(row.id),
      profileId: str(row.profile_id),
      name: str(row.name),
      slug: str(row.slug),
      description: str(row.description),
      public: Boolean(row.is_public),
      createdAt: str(row.created_at),
      updatedAt: str(row.updated_at),
      items: items.filter((item) => str(item.collection_id) === str(row.id)).map((item) => ({
        id: str(item.id),
        entityId: str(item.entity_id),
        entityKind: asKind(item.entity_kind),
        note: optStr(item.note),
        position: num(item.position) ?? 0,
      })),
    })),
    pins: pins.map(pinFromRow),
    genreAssertions: assertions.map(assertionFromRow),
    catalog,
  };
}

/** What any visitor may see about one person. Listening logs never leave here. */
export async function loadPublicBundleByHandle(handle: string): Promise<ProfileBundle & { catalog: CatalogSlice }> {
  const normalizedHandle = handle.replace(/^@/, '').toLowerCase();
  const profileRow = await first<Row>('select * from profiles where handle = ?', normalizedHandle);
  if (!profileRow) throw new Error('Profile not found.');
  const profile = profileFromRow(profileRow);
  const [likes, entries, collections, pins, assertions] = await Promise.all([
    all<Row>('select * from likes where profile_id = ? order by created_at asc', profile.id),
    loadEntriesFor(profile.id, false),
    all<Row>('select * from collections where profile_id = ? and is_public = 1 order by created_at asc', profile.id),
    all<Row>('select * from profile_pins where profile_id = ?', profile.id),
    all<Row>("select * from entity_genres where source = 'user' and created_by = ?", profile.id),
  ]);
  const collectionIds = collections.map((collection) => str(collection.id));
  const items = collectionIds.length
    ? await all<Row>(
        `select * from collection_items where collection_id in (${collectionIds.map(() => '?').join(',')}) order by position asc`,
        ...collectionIds,
      )
    : [];
  // Public pins may target entries or collections; expose only ones this visitor can see.
  const visibleEntryIds = new Set(entries.map((entry) => entry.id));
  const visibleCollectionIds = new Set(collections.map((collection) => collection.id));
  const visiblePins = pins.map(pinFromRow).filter((pin) =>
    pin.targetType === 'entity' ||
    (pin.targetType === 'entry' && visibleEntryIds.has(pin.targetId)) ||
    (pin.targetType === 'collection' && visibleCollectionIds.has(pin.targetId)),
  );

  const catalog = await collectReferencedCatalog([
    ...likes.map((row) => ({ kind: asKind(row.entity_kind), id: str(row.entity_id) })),
    ...entries.flatMap((entry) => [
      { kind: entry.entityKind, id: entry.entityId },
      ...entry.references.map((reference) => ({ kind: reference.entityKind as EntityKind, id: reference.entityId })),
    ]),
    ...items.map((row) => ({ kind: asKind(row.entity_kind), id: str(row.entity_id) })),
    ...(profile.profileSongId ? [{ kind: 'song' as EntityKind, id: profile.profileSongId }] : []),
  ]);

  return {
    profile,
    likes: likes.map(likeFromRow),
    entries,
    listens: [], // Private by design: a person's listening timeline ships only to themselves.
    collections: collections.map((row) => ({
      id: str(row.id),
      profileId: str(row.profile_id),
      name: str(row.name),
      slug: str(row.slug),
      description: str(row.description),
      public: true,
      createdAt: str(row.created_at),
      updatedAt: str(row.updated_at),
      items: items.filter((item) => str(item.collection_id) === str(row.id)).map((item) => ({
        id: str(item.id),
        entityId: str(item.entity_id),
        entityKind: asKind(item.entity_kind),
        note: optStr(item.note),
        position: num(item.position) ?? 0,
      })),
    })),
    pins: visiblePins,
    genreAssertions: assertions.map(assertionFromRow),
    catalog,
  };
}

/** Resolve catalog rows that live only in D1 (imports) so clients can render them. */
async function collectReferencedCatalog(references: Array<{ kind: EntityKind | 'entity'; id: string }>): Promise<CatalogSlice> {
  const artists = new Map<string, Artist>();
  const albums = new Map<string, Album>();
  const songs = new Map<string, Song>();

  const songIds = new Set<string>();
  const albumIds = new Set<string>();
  const directArtistIds = new Set<string>();

  for (const reference of references) {
    if (!reference.id) continue;
    if (reference.kind === 'artist') directArtistIds.add(reference.id);
    else if (reference.kind === 'album') albumIds.add(reference.id);
    else songIds.add(reference.id); // covers 'song' and legacy 'entity' tags on songs
  }

  for (const id of directArtistIds) {
    const row = await first<Row>('select * from artists where id = ?', id);
    if (row) artists.set(id, artistFromRow(row));
  }
  for (const id of albumIds) {
    const row = await first<Row>('select * from albums where id = ?', id);
    if (row) {
      albums.set(id, albumFromRow(row));
      directArtistIds.add(str(row.artist_id));
    }
  }
  for (const id of songIds) {
    const row = await first<Row>('select * from songs where id = ?', id);
    if (row) {
      songs.set(id, songFromRow(row));
      directArtistIds.add(str(row.artist_id));
      if (row.album_id) albumIds.add(str(row.album_id));
    }
  }
  for (const id of albumIds) {
    if (albums.has(id)) continue;
    const row = await first<Row>('select * from albums where id = ?', id);
    if (row) albums.set(id, albumFromRow(row));
  }
  for (const id of directArtistIds) {
    if (artists.has(id)) continue;
    const row = await first<Row>('select * from artists where id = ?', id);
    if (row) artists.set(id, artistFromRow(row));
  }
  return { artists: [...artists.values()], albums: [...albums.values()], songs: [...songs.values()] };
}

export function artistFromRow(row: Row): Artist {
  return {
    id: str(row.id),
    kind: 'artist',
    name: str(row.name),
    slug: str(row.slug),
    sortName: optStr(row.sort_name),
    country: optStr(row.country),
    imageUrl: optStr(row.image_url),
    musicbrainzId: optStr(row.musicbrainz_id),
    summary: optStr(row.summary),
  };
}

export function albumFromRow(row: Row): Album {
  return {
    id: str(row.id),
    kind: 'album',
    name: str(row.name),
    slug: str(row.slug),
    artistId: str(row.artist_id),
    year: num(row.release_year),
    releaseGroupType: optStr(row.release_group_type),
    imageUrl: optStr(row.image_url),
    musicbrainzId: optStr(row.musicbrainz_release_group_id),
    summary: optStr(row.summary),
  };
}

export function songFromRow(row: Row): Song {
  return {
    id: str(row.id),
    kind: 'song',
    name: str(row.name),
    slug: str(row.slug),
    artistId: str(row.artist_id),
    albumId: optStr(row.album_id),
    trackNumber: num(row.track_number),
    durationMs: num(row.duration_ms),
    isBonusTrack: Boolean(row.is_bonus_track),
    spotifyId: optStr(row.spotify_id),
    youtubeId: optStr(row.youtube_id),
    musicbrainzId: optStr(row.musicbrainz_recording_id),
    summary: optStr(row.summary),
  };
}

// --- Writes (ownership enforced via the session user id, never client input) ---

export async function saveLike(userId: string, input: { entityId: string; entityKind: EntityKind; clientVersion: number; liked: boolean; id: string }) {
  if (!input.liked) {
    await run('delete from likes where profile_id = ? and entity_id = ?', userId, input.entityId);
    return;
  }
  await run(
    `insert into likes (id, profile_id, entity_id, entity_kind, client_version)
     values (?, ?, ?, ?, ?)
     on conflict(profile_id, entity_id) do update set entity_kind = excluded.entity_kind, client_version = excluded.client_version`,
    input.id || randomUUID(), userId, input.entityId, input.entityKind, input.clientVersion,
  );
}

export async function saveGenreAssertion(userId: string, input: { entityId: string; entityKind: EntityKind; genreId: string; asserted: boolean }) {
  if (!input.asserted) {
    await run(
      "delete from entity_genres where source = 'user' and created_by = ? and entity_id = ? and genre_id = ?",
      userId, input.entityId, input.genreId,
    );
    return;
  }
  await run(
    `insert into entity_genres (id, entity_id, entity_kind, genre_id, source, created_by, votes)
     values (?, ?, ?, ?, 'user', ?, 1)
     on conflict(id) do nothing`,
    randomUUID(), input.entityId, input.entityKind, input.genreId, userId,
  );
}

export async function saveEntry(userId: string, entry: JournalEntry) {
  const existing = await first<Row>('select profile_id from journal_entries where id = ?', entry.id);
  if (existing && str(existing.profile_id) !== userId) throw new Error('Not your entry.');
  await run(
    `insert into journal_entries (id, profile_id, entity_id, entity_kind, title, document, plain_text, worked, didnt_work, lenses, is_public, created_at, updated_at)
     values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     on conflict(id) do update set
       title = excluded.title, document = excluded.document, plain_text = excluded.plain_text,
       worked = excluded.worked, didnt_work = excluded.didnt_work, lenses = excluded.lenses,
       is_public = excluded.is_public, updated_at = excluded.updated_at`,
    entry.id || randomUUID(), userId, entry.entityId, entry.entityKind, entry.title ?? null,
    JSON.stringify(entry.document), entry.plainText, entry.worked ?? null, entry.didntWork ?? null,
    JSON.stringify(entry.lenses), entry.public ? 1 : 0, entry.createdAt, entry.updatedAt,
  );
  await run('delete from entry_references where entry_id = ?', entry.id);
  for (const reference of entry.references) {
    await run(
      'insert or ignore into entry_references (id, entry_id, reference_id, entity_id, entity_kind, label, relation, lenses) values (?, ?, ?, ?, ?, ?, ?, ?)',
      reference.id || randomUUID(), entry.id, reference.id, reference.entityId, reference.entityKind,
      reference.label, reference.relation, JSON.stringify(reference.lenses),
    );
  }
}

export async function saveListen(userId: string, listen: ListenLog) {
  await run(
    'insert into listen_logs (id, profile_id, song_id, moods, note, listened_at) values (?, ?, ?, ?, ?, ?)',
    listen.id || randomUUID(), userId, listen.songId, JSON.stringify(listen.moods), listen.note ?? null, listen.listenedAt,
  );
}

export async function saveCollection(userId: string, collection: Collection) {
  const existing = await first<Row>('select profile_id from collections where id = ?', collection.id);
  if (existing && str(existing.profile_id) !== userId) throw new Error('Not your collection.');
  await run(
    `insert into collections (id, profile_id, name, slug, description, is_public, created_at, updated_at)
     values (?, ?, ?, ?, ?, ?, ?, ?)
     on conflict(id) do update set name = excluded.name, slug = excluded.slug, description = excluded.description,
       is_public = excluded.is_public, updated_at = excluded.updated_at`,
    collection.id || randomUUID(), userId, collection.name, collection.slug, collection.description,
    collection.public ? 1 : 0, collection.createdAt, collection.updatedAt,
  );
  await run('delete from collection_items where collection_id = ?', collection.id);
  for (const item of collection.items) {
    await run(
      'insert or ignore into collection_items (id, collection_id, entity_id, entity_kind, note, position) values (?, ?, ?, ?, ?, ?)',
      item.id || randomUUID(), collection.id, item.entityId, item.entityKind, item.note ?? null, item.position,
    );
  }
}

export async function savePin(userId: string, input: { targetType: ProfilePin['targetType']; targetId: string; position: number; pinned: boolean }) {
  if (!input.pinned) {
    await run('delete from profile_pins where profile_id = ? and target_type = ? and target_id = ?', userId, input.targetType, input.targetId);
    return;
  }
  await run(
    `insert into profile_pins (id, profile_id, target_type, target_id, position) values (?, ?, ?, ?, ?)
     on conflict(profile_id, target_type, target_id) do update set position = excluded.position`,
    randomUUID(), userId, input.targetType, input.targetId, input.position,
  );
}

export async function saveProfileFields(userId: string, profile: Pick<Profile, 'displayName' | 'bio' | 'avatarUrl' | 'profileSongId' | 'genreIds'>) {
  await run(
    'update profiles set display_name = ?, bio = ?, avatar_url = ?, profile_song_id = ?, genre_ids = ? where id = ?',
    profile.displayName, profile.bio, profile.avatarUrl ?? null, profile.profileSongId ?? null,
    JSON.stringify(profile.genreIds ?? []), userId,
  );
}

// --- Catalog upserts for the import worker ---

async function insertWithSlugRetry(table: 'artists' | 'albums' | 'songs', build: (slugSuffix: number) => Record<string, unknown>): Promise<void> {
  for (let attempt = 0; attempt < 4; attempt += 1) {
    try {
      const row = build(attempt === 0 ? 0 : attempt + 1);
      const columns = Object.keys(row);
      await run(
        `insert or ignore into ${table} (${columns.join(', ')}) values (${columns.map(() => '?').join(', ')})`,
        ...Object.values(row),
      );
      return;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (!message.includes('UNIQUE')) throw error;
    }
  }
}

export async function upsertImportedCatalog(slice: CatalogSlice): Promise<void> {
  for (const artist of slice.artists) {
    await insertWithSlugRetry('artists', (suffix) => ({
      id: artist.id,
      name: artist.name,
      slug: suffix ? `${artist.slug}-${suffix}` : artist.slug,
      sort_name: artist.sortName ?? null,
      country: artist.country ?? null,
      image_url: null,
      musicbrainz_id: artist.musicbrainzId ?? null,
      summary: artist.summary ?? null,
    }));
  }
  for (const album of slice.albums) {
    await insertWithSlugRetry('albums', (suffix) => ({
      id: album.id,
      artist_id: album.artistId,
      name: album.name,
      slug: suffix ? `${album.slug}-${suffix}` : album.slug,
      release_year: album.year ?? null,
      release_group_type: album.releaseGroupType ?? null,
      image_url: album.imageUrl ?? null,
      musicbrainz_release_group_id: album.musicbrainzId ?? null,
      summary: album.summary ?? null,
    }));
  }
  for (const song of slice.songs) {
    await insertWithSlugRetry('songs', (suffix) => ({
      id: song.id,
      artist_id: song.artistId,
      album_id: song.albumId ?? null,
      name: song.name,
      slug: suffix ? `${song.slug}-${suffix}` : song.slug,
      track_number: song.trackNumber ?? null,
      duration_ms: song.durationMs ?? null,
      is_bonus_track: song.isBonusTrack ? 1 : 0,
      musicbrainz_recording_id: song.musicbrainzId ?? null,
      spotify_id: song.spotifyId ?? null,
      youtube_id: song.youtubeId ?? null,
      summary: song.summary ?? null,
    }));
  }
}

/** Slug-path resolution so permanent pages work for entities stored only in D1. */
export async function resolveCatalogPath(segments: string[]): Promise<CatalogSlice> {
  const slice: CatalogSlice = { artists: [], albums: [], songs: [] };
  if (!segments.length) return slice;
  const artist = await first<Row>('select * from artists where slug = ?', segments[0]);
  if (!artist) return slice;
  slice.artists.push(artistFromRow(artist));

  if (segments.length >= 2) {
    const album = await first<Row>('select * from albums where artist_id = ? and slug = ?', str(artist.id), segments[1]);
    if (album) {
      slice.albums.push(albumFromRow(album));
      // Album pages render their whole tracklist, so bring every track along.
      const tracks = await all<Row>('select * from songs where album_id = ? order by track_number', str(album.id));
      slice.songs.push(...tracks.map(songFromRow));
    }
  }
  if (segments.length >= 3 && !slice.songs.some((song) => song.slug === segments[2])) {
    const song = await first<Row>('select * from songs where artist_id = ? and slug = ?', str(artist.id), segments[2]);
    if (song) slice.songs.push(songFromRow(song));
  }
  return slice;
}
