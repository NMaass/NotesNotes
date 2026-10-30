import 'server-only';
import { randomUUID } from 'node:crypto';
import { all, allIn, batch, first, run, sql, type Statement } from '@/lib/server/db';
import { storedEntryTimes } from '@/lib/server/timestamps';
import { catalog as seed } from '@/lib/data/catalog';
import type {
  Album,
  Artist,
  Collection,
  EntityGenre,
  EntityKind,
  Genre,
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
  /** Genres the payload references, seeded or stored in D1. */
  genres?: Genre[];
}

/** A write aimed at a row that belongs to someone else. Routes answer 403, never 500. */
export class OwnershipError extends Error {}

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
  // SQL NULL is "unknown", not zero (Number(null) would be 0).
  if (value === null || value === undefined || value === '') return undefined;
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

/**
 * Whether a written entry or collection is published. Only `published === true`
 * publishes; the legacy `public` key is ignored, because builds that predate the
 * flag sent `public: true` by default (docs/IOS_API.md, "Private first").
 */
export function isPublished(input: { published?: unknown }): boolean {
  return input.published === true;
}

/** Both wire names for the stored flag, so builds that read only `public` stay right. */
function visibility(row: Row): { public: boolean; published: boolean } {
  const published = Boolean(row.is_public);
  return { public: published, published };
}

// --- Row mappers (shapes mirror the previous Postgres adapter exactly) ---

export function profileFromRow(row: Row): Profile {
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

export function entryFromRow(row: Row, references: MusicReference[]): JournalEntry {
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
    ...visibility(row),
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

function collectionFromRow(row: Row, items: Row[]): Collection {
  return {
    id: str(row.id),
    profileId: str(row.profile_id),
    name: str(row.name),
    slug: str(row.slug),
    description: str(row.description),
    ...visibility(row),
    createdAt: str(row.created_at),
    updatedAt: str(row.updated_at),
    items: items.filter((item) => str(item.collection_id) === str(row.id)).map((item) => ({
      id: str(item.id),
      entityId: str(item.entity_id),
      entityKind: asKind(item.entity_kind),
      note: optStr(item.note),
      position: num(item.position) ?? 0,
    })),
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

/** Attaches each entry's references (one query per 90 entries) and maps the rows. */
export async function hydrateEntries(rows: Row[]): Promise<JournalEntry[]> {
  if (!rows.length) return [];
  const references = await allIn<Row>(
    (list) => `select * from entry_references where entry_id in (${list})`,
    rows.map((row) => str(row.id)),
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

async function loadEntriesFor(profileId: string, includePrivate: boolean): Promise<JournalEntry[]> {
  const rows = await all<Row>(
    includePrivate
      ? 'select * from journal_entries where profile_id = ? order by updated_at desc'
      : 'select * from journal_entries where profile_id = ? and is_public = 1 order by updated_at desc',
    profileId,
  );
  return hydrateEntries(rows);
}

/**
 * Every catalog id a bundle points at, so those rows can ship alongside: the
 * native app keeps no copy of the seed catalog, and D1 imports exist nowhere else.
 */
function bundleReferences(input: {
  profile: Profile;
  likes: Row[];
  entries: JournalEntry[];
  items: Row[];
  assertions: Row[];
  listens?: Row[];
  pins?: ProfilePin[];
}): CatalogReference[] {
  return [
    ...input.likes.map((row) => ({ kind: asKind(row.entity_kind), id: str(row.entity_id) })),
    ...input.entries.flatMap((entry) => [
      { kind: entry.entityKind, id: entry.entityId },
      ...entry.references.map((reference) => ({ kind: reference.entityKind as EntityKind, id: reference.entityId })),
    ]),
    ...input.items.map((row) => ({ kind: asKind(row.entity_kind), id: str(row.entity_id) })),
    ...(input.profile.profileSongId ? [{ kind: 'song' as EntityKind, id: input.profile.profileSongId }] : []),
    ...(input.listens ?? []).map((row) => ({ kind: 'song' as EntityKind, id: str(row.song_id) })),
    // Pinned entities carry no kind; collectReferencedCatalog looks them up in every table.
    ...(input.pins ?? []).filter((pin) => pin.targetType === 'entity').map((pin) => ({ kind: 'entity' as const, id: pin.targetId })),
    // Genres tagged from the phone may exist only in D1; the web must be able to render them.
    ...input.assertions.flatMap((row) => [
      { kind: asKind(row.entity_kind), id: str(row.entity_id) },
      { kind: 'genre' as EntityKind, id: str(row.genre_id) },
    ]),
    ...input.profile.genreIds.map((id) => ({ kind: 'genre' as EntityKind, id })),
  ];
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
  const items = (await allIn<Row>(
    (list) => `select * from collection_items where collection_id in (${list})`,
    collectionIds,
  )).sort((a, b) => (num(a.position) ?? 0) - (num(b.position) ?? 0));

  const pinList = pins.map(pinFromRow);
  const catalog = await collectReferencedCatalog(bundleReferences({ profile, likes, entries, items, assertions, listens, pins: pinList }));

  return {
    profile,
    likes: likes.map(likeFromRow),
    entries,
    listens: listens.map(listenFromRow),
    collections: collections.map((row) => collectionFromRow(row, items)),
    pins: pinList,
    genreAssertions: assertions.map(assertionFromRow),
    catalog,
  };
}

/**
 * What any visitor (the owner included) may see about one person: the profile,
 * published entries and collections, pins on entities and on published writing,
 * and genre assertions. Likes and listens never leave here; they ship as empty
 * arrays so older builds decode, and the catalog slice carries nothing only they needed.
 */
export async function loadPublicBundleByHandle(handle: string): Promise<ProfileBundle & { catalog: CatalogSlice }> {
  const normalizedHandle = handle.replace(/^@/, '').toLowerCase();
  const profileRow = await first<Row>('select * from profiles where handle = ?', normalizedHandle);
  if (!profileRow) throw new Error('Profile not found.');
  const profile = profileFromRow(profileRow);
  const [entries, collections, pins, assertions] = await Promise.all([
    loadEntriesFor(profile.id, false),
    all<Row>('select * from collections where profile_id = ? and is_public = 1 order by created_at asc', profile.id),
    all<Row>('select * from profile_pins where profile_id = ?', profile.id),
    all<Row>("select * from entity_genres where source = 'user' and created_by = ?", profile.id),
  ]);
  const collectionIds = collections.map((collection) => str(collection.id));
  const items = (await allIn<Row>(
    (list) => `select * from collection_items where collection_id in (${list})`,
    collectionIds,
  )).sort((a, b) => (num(a.position) ?? 0) - (num(b.position) ?? 0));
  // Public pins may target entries or collections; expose only ones this visitor can see.
  const visibleEntryIds = new Set(entries.map((entry) => entry.id));
  const visibleCollectionIds = new Set(collections.map((collection) => collection.id));
  const visiblePins = pins.map(pinFromRow).filter((pin) =>
    pin.targetType === 'entity' ||
    (pin.targetType === 'entry' && visibleEntryIds.has(pin.targetId)) ||
    (pin.targetType === 'collection' && visibleCollectionIds.has(pin.targetId)),
  );

  const catalog = await collectReferencedCatalog(bundleReferences({ profile, likes: [], entries, items, assertions, pins: visiblePins }));

  return {
    profile,
    likes: [], // Private: what someone likes ships only to themselves.
    entries,
    listens: [], // Private by design: a person's listening timeline ships only to themselves.
    collections: collections.map((row) => collectionFromRow(row, items)),
    pins: visiblePins,
    genreAssertions: assertions.map(assertionFromRow),
    catalog,
  };
}

export type CatalogReference = { kind: EntityKind | 'entity'; id: string };

/**
 * The catalog rows behind a set of references, seeded (from code) and stored
 * (D1) alike, so a client without the seed catalog can render every one. Songs
 * bring their album and artist; albums bring their artist. References of kind
 * 'entity' (pins) are looked up in every table. Four rounds of
 * `where id in (...)` at most, whatever the count.
 */
export async function collectReferencedCatalog(references: CatalogReference[]): Promise<CatalogSlice> {
  const artists = new Map<string, Artist>();
  const albums = new Map<string, Album>();
  const songs = new Map<string, Song>();
  const genres = new Map<string, Genre>();
  const want = { artist: new Set<string>(), album: new Set<string>(), song: new Set<string>(), genre: new Set<string>() };

  const addSeedSong = (song: Song) => {
    songs.set(song.id, song);
    want.artist.add(song.artistId);
    if (song.albumId) want.album.add(song.albumId);
  };
  for (const reference of references) {
    const { id } = reference;
    if (!id) continue;
    if (reference.kind === 'entity') {
      // Pins name an id without a kind: take the seeded row if there is one, else ask every table.
      const local = seed.songs.get(id) ?? seed.albums.get(id) ?? seed.artists.get(id) ?? seed.genres.get(id);
      if (local?.kind === 'song') addSeedSong(local);
      else if (local?.kind === 'album') albums.set(id, local);
      else if (local?.kind === 'artist') artists.set(id, local);
      else if (local?.kind === 'genre') genres.set(id, local);
      else for (const set of Object.values(want)) set.add(id);
      continue;
    }
    if (reference.kind === 'genre') {
      const local = seed.genres.get(id);
      if (local) genres.set(id, local);
      else want.genre.add(id);
    } else if (reference.kind === 'artist') want.artist.add(id);
    else if (reference.kind === 'album') want.album.add(id);
    else {
      // 'song' (and legacy kind-less tags on songs)
      const local = seed.songs.get(id);
      if (local) addSeedSong(local);
      else want.song.add(id);
    }
  }

  const missing = (set: Set<string>, found: Map<string, unknown>) => [...set].filter((id) => !found.has(id));
  const [songRows, genreRows] = await Promise.all([
    allIn<Row>((list) => `select * from songs where id in (${list})`, missing(want.song, songs)),
    allIn<Row>((list) => `select * from genres where id in (${list})`, missing(want.genre, genres)),
  ]);
  for (const row of songRows) {
    const song = songFromRow(row);
    songs.set(song.id, song);
    want.artist.add(song.artistId);
    if (song.albumId) want.album.add(song.albumId);
  }
  for (const row of genreRows) genres.set(str(row.id), genreFromRow(row));

  for (const id of want.album) {
    const local = seed.albums.get(id);
    if (local) albums.set(id, local);
  }
  const albumRows = await allIn<Row>((list) => `select * from albums where id in (${list})`, missing(want.album, albums));
  for (const row of albumRows) albums.set(str(row.id), albumFromRow(row));
  for (const album of albums.values()) want.artist.add(album.artistId);

  for (const id of want.artist) {
    const local = seed.artists.get(id);
    if (local) artists.set(id, local);
  }
  const artistRows = await allIn<Row>((list) => `select * from artists where id in (${list})`, missing(want.artist, artists));
  for (const row of artistRows) artists.set(str(row.id), artistFromRow(row));

  return { artists: [...artists.values()], albums: [...albums.values()], songs: [...songs.values()], genres: [...genres.values()] };
}

export function genreFromRow(row: Row): Genre {
  return {
    id: str(row.id),
    kind: 'genre',
    name: str(row.name),
    slug: str(row.slug),
    musicbrainzId: optStr(row.musicbrainz_id),
    description: optStr(row.description),
  };
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

/**
 * One assertion per person, entity, and genre: a resent assertion is a no-op
 * (`where not exists`, backed by the entity_genres_user_uq index), so retries
 * never add a second vote.
 */
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
     select ?, ?, ?, ?, 'user', ?, 1
     where not exists (select 1 from entity_genres where source = 'user' and created_by = ? and entity_id = ? and genre_id = ?)
     on conflict do nothing`,
    randomUUID(), input.entityId, input.entityKind, input.genreId, userId,
    userId, input.entityId, input.genreId,
  );
}

export async function saveEntry(userId: string, entry: JournalEntry) {
  const existing = await first<Row>('select profile_id from journal_entries where id = ?', entry.id);
  if (existing && str(existing.profile_id) !== userId) throw new OwnershipError('That entry belongs to another account.');
  // Public surfaces order by these: never later than now, always a readable ISO time.
  const { createdAt, updatedAt } = storedEntryTimes(entry);
  // One batch: the entry and its reference rows change together or not at all.
  await batch([
    sql(
      `insert into journal_entries (id, profile_id, entity_id, entity_kind, title, document, plain_text, worked, didnt_work, lenses, is_public, created_at, updated_at)
       values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       on conflict(id) do update set
         title = excluded.title, document = excluded.document, plain_text = excluded.plain_text,
         worked = excluded.worked, didnt_work = excluded.didnt_work, lenses = excluded.lenses,
         is_public = excluded.is_public, updated_at = excluded.updated_at`,
      entry.id || randomUUID(), userId, entry.entityId, entry.entityKind, entry.title ?? null,
      JSON.stringify(entry.document), entry.plainText, entry.worked ?? null, entry.didntWork ?? null,
      JSON.stringify(entry.lenses), isPublished(entry) ? 1 : 0, createdAt, updatedAt,
    ),
    sql('delete from entry_references where entry_id = ?', entry.id),
    ...(entry.references ?? []).map((reference): Statement => sql(
      'insert or ignore into entry_references (id, entry_id, reference_id, entity_id, entity_kind, label, relation, lenses) values (?, ?, ?, ?, ?, ?, ?, ?)',
      reference.id || randomUUID(), entry.id, reference.id, reference.entityId, reference.entityKind,
      reference.label, reference.relation, JSON.stringify(reference.lenses),
    )),
  ]);
}

/**
 * Outcome of a delete. A row that no longer exists counts as deleted, so a
 * resent delete (or a delete of something that never reached the server) is a
 * success; only someone else's row is refused.
 */
export type DeleteOutcome = 'deleted' | 'absent' | 'not-yours';

/** Deletes the caller's entry with its references and any pins on it. */
export async function deleteEntry(userId: string, id: string): Promise<DeleteOutcome> {
  const existing = await first<Row>('select profile_id from journal_entries where id = ?', id);
  if (existing && str(existing.profile_id) !== userId) return 'not-yours';
  if (!existing) {
    // Already gone. Drop any pin the caller still has on it and report success.
    await run("delete from profile_pins where profile_id = ? and target_type = 'entry' and target_id = ?", userId, id);
    return 'absent';
  }
  await batch([
    sql('delete from entry_references where entry_id = ?', id),
    sql("delete from profile_pins where target_type = 'entry' and target_id = ?", id),
    sql('delete from journal_entries where id = ? and profile_id = ?', id, userId),
  ]);
  return 'deleted';
}

/**
 * Idempotent by id: resending a listen (the native outbox retries after a lost
 * response) updates the same row instead of failing on the primary key. A listen
 * id that belongs to someone else is refused.
 */
export async function saveListen(userId: string, listen: ListenLog) {
  const id = listen.id || randomUUID();
  const existing = listen.id ? await first<Row>('select profile_id from listen_logs where id = ?', id) : null;
  if (existing && str(existing.profile_id) !== userId) throw new OwnershipError('That listen belongs to another account.');
  await run(
    `insert into listen_logs (id, profile_id, song_id, moods, note, listened_at) values (?, ?, ?, ?, ?, ?)
     on conflict(id) do update set song_id = excluded.song_id, moods = excluded.moods, note = excluded.note, listened_at = excluded.listened_at
     where listen_logs.profile_id = excluded.profile_id`,
    id, userId, listen.songId, JSON.stringify(listen.moods ?? []), listen.note ?? null, listen.listenedAt,
  );
}

export async function saveCollection(userId: string, collection: Collection) {
  const existing = await first<Row>('select profile_id from collections where id = ?', collection.id);
  if (existing && str(existing.profile_id) !== userId) throw new OwnershipError('That collection belongs to another account.');
  await batch([
    sql(
      `insert into collections (id, profile_id, name, slug, description, is_public, created_at, updated_at)
       values (?, ?, ?, ?, ?, ?, ?, ?)
       on conflict(id) do update set name = excluded.name, slug = excluded.slug, description = excluded.description,
         is_public = excluded.is_public, updated_at = excluded.updated_at`,
      collection.id || randomUUID(), userId, collection.name, collection.slug, collection.description,
      isPublished(collection) ? 1 : 0, collection.createdAt, collection.updatedAt,
    ),
    sql('delete from collection_items where collection_id = ?', collection.id),
    ...(collection.items ?? []).map((item): Statement => sql(
      'insert or ignore into collection_items (id, collection_id, entity_id, entity_kind, note, position) values (?, ?, ?, ?, ?, ?)',
      item.id || randomUUID(), collection.id, item.entityId, item.entityKind, item.note ?? null, item.position,
    )),
  ]);
}

/** Deletes the caller's collection with its items and any pins on it. */
export async function deleteCollection(userId: string, id: string): Promise<DeleteOutcome> {
  const existing = await first<Row>('select profile_id from collections where id = ?', id);
  if (existing && str(existing.profile_id) !== userId) return 'not-yours';
  if (!existing) {
    await run("delete from profile_pins where profile_id = ? and target_type = 'collection' and target_id = ?", userId, id);
    return 'absent';
  }
  await batch([
    sql('delete from collection_items where collection_id = ?', id),
    sql("delete from profile_pins where target_type = 'collection' and target_id = ?", id),
    sql('delete from collections where id = ? and profile_id = ?', id, userId),
  ]);
  return 'deleted';
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

function isUniqueViolation(error: unknown): boolean {
  return (error instanceof Error ? error.message : String(error)).includes('UNIQUE');
}

/** The first of `base`, `base-2`, `base-3`, … that is not taken (then a stable id-based suffix). */
function freeSlug(base: string, taken: Set<string>, id: string): string {
  if (!taken.has(base)) return base;
  for (let suffix = 2; suffix <= 20; suffix += 1) {
    if (!taken.has(`${base}-${suffix}`)) return `${base}-${suffix}`;
  }
  return `${base}-${id.replace(/^mb-[a-z]+-/, '').slice(0, 8)}`;
}

/**
 * Plans one batch that inserts every row of the slice that is not stored yet,
 * with slugs chosen against the rows already there: artist slugs are unique
 * everywhere, album slugs per artist, song slugs per artist and album. The
 * slice's entities take the slugs they are (or will be) stored under, so the
 * bundle a route returns links to the right pages.
 */
async function planCatalogInserts(slice: CatalogSlice, baseSlugs: Map<string, string>): Promise<Statement[]> {
  const base = (entity: { id: string; slug: string }) => baseSlugs.get(entity.id) ?? entity.slug;
  const [storedArtists, storedAlbums, storedSongs] = await Promise.all([
    allIn<Row>((list) => `select id, slug from artists where id in (${list})`, slice.artists.map((artist) => artist.id)),
    allIn<Row>((list) => `select id, slug from albums where id in (${list})`, slice.albums.map((album) => album.id)),
    allIn<Row>((list) => `select id, slug from songs where id in (${list})`, slice.songs.map((song) => song.id)),
  ]);
  const storedSlugs = new Map([...storedArtists, ...storedAlbums, ...storedSongs].map((row) => [str(row.id), str(row.slug)]));
  for (const entity of [...slice.artists, ...slice.albums, ...slice.songs]) {
    const slug = storedSlugs.get(entity.id);
    if (slug) entity.slug = slug;
  }
  const stored = new Set(storedSlugs.keys());
  const artists = slice.artists.filter((artist) => !stored.has(artist.id));
  const albums = slice.albums.filter((album) => !stored.has(album.id));
  const songs = slice.songs.filter((song) => !stored.has(song.id));
  if (!artists.length && !albums.length && !songs.length) return [];

  const slugVariants = (slug: string) => [slug, ...Array.from({ length: 19 }, (_, index) => `${slug}-${index + 2}`)];
  const [artistSlugRows, albumSlugRows, songSlugRows] = await Promise.all([
    allIn<Row>((list) => `select slug from artists where slug in (${list})`, artists.flatMap((artist) => slugVariants(base(artist)))),
    allIn<Row>((list) => `select artist_id, slug from albums where artist_id in (${list})`, albums.map((album) => album.artistId)),
    allIn<Row>((list) => `select artist_id, album_id, slug from songs where album_id in (${list})`, songs.flatMap((song) => (song.albumId ? [song.albumId] : []))),
  ]);
  const takenArtistSlugs = new Set(artistSlugRows.map((row) => str(row.slug)));
  const takenAlbumSlugs = new Set(albumSlugRows.map((row) => `${str(row.artist_id)}|${str(row.slug)}`));
  const takenSongSlugs = new Set(songSlugRows.map((row) => `${str(row.artist_id)}|${str(row.album_id)}|${str(row.slug)}`));

  const rows: Record<'artists' | 'albums' | 'songs', Array<Record<string, unknown>>> = { artists: [], albums: [], songs: [] };
  const insert = (table: 'artists' | 'albums' | 'songs', row: Record<string, unknown>) => rows[table].push(row);
  for (const artist of artists) {
    const slug = freeSlug(base(artist), takenArtistSlugs, artist.id);
    takenArtistSlugs.add(slug);
    artist.slug = slug;
    insert('artists', {
      id: artist.id,
      name: artist.name,
      slug,
      sort_name: artist.sortName ?? null,
      country: artist.country ?? null,
      image_url: null,
      musicbrainz_id: artist.musicbrainzId ?? null,
      summary: artist.summary ?? null,
    });
  }
  for (const album of albums) {
    const scoped = new Set([...takenAlbumSlugs].filter((key) => key.startsWith(`${album.artistId}|`)).map((key) => key.slice(album.artistId.length + 1)));
    const slug = freeSlug(base(album), scoped, album.id);
    takenAlbumSlugs.add(`${album.artistId}|${slug}`);
    album.slug = slug;
    insert('albums', {
      id: album.id,
      artist_id: album.artistId,
      name: album.name,
      slug,
      release_year: album.year ?? null,
      release_group_type: album.releaseGroupType ?? null,
      image_url: album.imageUrl ?? null,
      musicbrainz_release_group_id: album.musicbrainzId ?? null,
      summary: album.summary ?? null,
    });
  }
  for (const song of songs) {
    // SQLite treats NULL album ids as distinct, so album-less songs never clash.
    const scope = `${song.artistId}|${song.albumId ?? ''}|`;
    const scoped = song.albumId
      ? new Set([...takenSongSlugs].filter((key) => key.startsWith(scope)).map((key) => key.slice(scope.length)))
      : new Set<string>();
    const slug = freeSlug(base(song), scoped, song.id);
    if (song.albumId) takenSongSlugs.add(`${scope}${slug}`);
    song.slug = slug;
    insert('songs', {
      id: song.id,
      artist_id: song.artistId,
      album_id: song.albumId ?? null,
      name: song.name,
      slug,
      track_number: song.trackNumber ?? null,
      duration_ms: song.durationMs ?? null,
      is_bonus_track: song.isBonusTrack ? 1 : 0,
      musicbrainz_recording_id: song.musicbrainzId ?? null,
      spotify_id: song.spotifyId ?? null,
      youtube_id: song.youtubeId ?? null,
      summary: song.summary ?? null,
    });
  }
  // Multi-row inserts, as many rows per statement as D1's 100 bound parameters allow,
  // so a long tracklist costs a few statements rather than one per track.
  const statements: Statement[] = [];
  for (const table of ['artists', 'albums', 'songs'] as const) {
    const list = rows[table];
    if (!list.length) continue;
    const columns = Object.keys(list[0]);
    const perStatement = Math.max(1, Math.floor(100 / columns.length));
    for (let index = 0; index < list.length; index += perStatement) {
      const chunk = list.slice(index, index + perStatement);
      // An existing id means "already imported" (a concurrent import got there first).
      statements.push(sql(
        `insert into ${table} (${columns.join(', ')}) values ${chunk.map(() => `(${columns.map(() => '?').join(', ')})`).join(', ')} on conflict(id) do nothing`,
        ...chunk.flatMap((row) => columns.map((column) => row[column])),
      ));
    }
  }
  return statements;
}

/**
 * Stores an import in one D1 batch (atomic, and a handful of queries whatever
 * the tracklist length). A slug taken by a concurrent import between planning
 * and writing fails the batch as a whole; it is planned again against the new rows.
 */
export async function upsertImportedCatalog(slice: CatalogSlice): Promise<void> {
  // Planning rewrites the slice's slugs; a retry starts again from the ones the import proposed.
  const baseSlugs = new Map([...slice.artists, ...slice.albums, ...slice.songs].map((entity) => [entity.id, entity.slug]));
  for (let attempt = 0; ; attempt += 1) {
    try {
      await batch(await planCatalogInserts(slice, baseSlugs));
      return;
    } catch (error) {
      if (attempt >= 2 || !isUniqueViolation(error)) throw error;
    }
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

/** A genre stored only in D1 (e.g. a MusicBrainz genre tagged from the phone), by slug. */
export async function findStoredGenreBySlug(slug: string): Promise<Genre | null> {
  const row = await first<Row>('select * from genres where slug = ?', slug);
  return row ? genreFromRow(row) : null;
}
