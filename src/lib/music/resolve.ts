import 'server-only';
// POST /api/music/resolve: map what someone is listening to onto a permanent
// catalog song, importing it from MusicBrainz when needed, and suggest what to
// write. Local reads come first (cache, D1, seed); MusicBrainz work is bounded
// by a deadline so a request never runs much past ~20 s.
import { catalog as seed, songs as seedSongs } from '@/lib/data/catalog';
import { aliases as seedAliases } from '@/lib/data/selectors';
import type { Album, Artist, Genre, MusicLens, SearchResult, Song } from '@/lib/data/types';
import {
  fetchLinkMetadata,
  parseMusicLink,
  type ParsedLink,
} from '@/lib/music/links';
import {
  classifyCandidate,
  durationCloseness,
  fallbackSearchQuery,
  isrcKey,
  keyRank,
  mbidKey,
  pickIsrcRecording,
  preferredRelease,
  rankRecordings,
  recordingSearchQuery,
  recordingToSearchResult,
  resolutionKeys,
  textKey,
  topGenres,
  trackNamesSong,
  trackPlausiblyIs,
  type Confidence,
  type MbArtistCredit,
  type MbGenre,
  type MbRecording,
} from '@/lib/music/matching';
import {
  fetchGenres,
  fetchRecording,
  lookupIsrc,
  MusicBrainzDeadlineError,
  resolveImport,
  searchRecordings,
} from '@/lib/music/musicbrainz';
import type { NowPlayingTrack } from '@/lib/music/scrobbles';
import {
  orderGenreSuggestions,
  pickPrompt,
  rankLenses,
  rankMoods,
  type GenreSuggestion,
  type WeightedGenre,
} from '@/lib/music/suggestions';
import { artistLikePattern, cleanTitle, fold, genreDisplayName, likePattern, matchKey, sameArtist, sameTitle } from '@/lib/music/text';
import { genresForEntities, loadEntity } from '@/lib/server/catalog';
import { all, allIn, batch, first, sql, type Statement } from '@/lib/server/db';
import { genreFromRow, songFromRow, upsertImportedCatalog } from '@/lib/server/repo';
import { slugify } from '@/lib/utils';

type Row = Record<string, unknown>;

/** Time allowed for MusicBrainz work; D1 reads and the response fit in the rest of ~20 s. */
const MUSICBRAINZ_BUDGET_MS = 17_000;
const MAX_SUGGESTED_GENRES = 4;

export interface ResolveResult {
  ok: true;
  track?: NowPlayingTrack;
  song?: Song;
  album?: Album;
  artist?: Artist;
  confidence: Confidence;
  candidates: SearchResult[];
  suggestions: { genres: GenreSuggestion[]; lenses: MusicLens[]; moods: string[]; prompt: string };
  entriesCount: number;
}

/** A link that parsed but no provider would describe. */
export class LinkUnreadableError extends Error {}

/** A cache key the server verified, and the confidence it may be stored with. */
interface VerifiedKey { key: string; confidence: 'exact' | 'strong' }

interface Match {
  song: Song;
  confidence: 'exact' | 'strong';
  fromCache: boolean;
  /** MusicBrainz genres already in hand from the import, keyed by entity id. */
  musicbrainzGenres?: Map<string, MbGenre[]>;
  /**
   * The identifiers this match proves, and only those: a recording id
   * MusicBrainz resolved, an ISRC MusicBrainz listed. Client-sent ids that played
   * no part in the match are never cached. (`text:` keys are added later, when
   * the track's title and artist name the matched song.)
   */
  verifiedKeys: VerifiedKey[];
}

interface Attempt {
  match?: Match;
  /** Recordings seen along the way, offered when nothing is certain enough. */
  candidates: MbRecording[];
}

function parseJson<T>(value: unknown, fallback: T): T {
  try {
    return typeof value === 'string' && value ? JSON.parse(value) as T : fallback;
  } catch {
    return fallback;
  }
}

// --- Local lookups ---

function durationAgrees(a?: number, b?: number): boolean {
  return durationCloseness(a, b) !== 'far';
}

/** A seeded song by artist + title (seed rows carry no recording ids). */
function seedSongByText(title: string, artist: string, durationMs?: number): Song | undefined {
  return seedSongs.find((song) => {
    const owner = seed.artists.get(song.artistId);
    if (!owner || !sameTitle(song.name, title) || !durationAgrees(song.durationMs, durationMs)) return false;
    return [owner.name, ...(seedAliases[owner.id] ?? [])].some((name) => sameArtist(artist, name));
  });
}

/**
 * A seeded song the recording is a version of: same title, by the credited
 * MusicBrainz artist or on one of the recording's release groups (seed songs
 * carry no recording ids, but seed artists and albums carry MusicBrainz ids).
 */
function seedSongForRecording(recording: Pick<MbRecording, 'title' | 'artist-credit' | 'length' | 'releases'>): Song | undefined {
  const artistMbids = new Set((recording['artist-credit'] ?? []).map((credit: MbArtistCredit) => credit.artist?.id).filter(Boolean));
  const groupMbids = new Set((recording.releases ?? []).map((release) => release['release-group']?.id).filter(Boolean));
  if (!recording.title || (!artistMbids.size && !groupMbids.size)) return undefined;
  return seedSongs.find((song) => {
    if (!sameTitle(song.name, recording.title!) || !durationAgrees(song.durationMs, recording.length ?? undefined)) return false;
    const owner = seed.artists.get(song.artistId);
    const album = song.albumId ? seed.albums.get(song.albumId) : undefined;
    return Boolean((owner?.musicbrainzId && artistMbids.has(owner.musicbrainzId)) || (album?.musicbrainzId && groupMbids.has(album.musicbrainzId)));
  });
}

/**
 * A track with the same title on the album this recording would import into,
 * when that album is already in D1. Another pressing of the album may carry a
 * different recording of the same track; reusing it avoids duplicate tracks.
 */
async function d1AlbumTrackForRecording(recording: MbRecording): Promise<Song | undefined> {
  const group = preferredRelease(recording.releases)?.['release-group']?.id;
  if (!group || !recording.title) return undefined;
  const rows = await all<Row>('select * from songs where album_id = ?', `mb-album-${group}`);
  const row = rows.find((candidate) => sameTitle(String(candidate.name), recording.title!));
  return row ? songFromRow(row) : undefined;
}

async function d1SongByRecording(mbid: string): Promise<Song | undefined> {
  const row = await first<Row>('select * from songs where musicbrainz_recording_id = ?', mbid.toLowerCase());
  return row ? songFromRow(row) : undefined;
}

/**
 * D1 songs whose normalized title and artist agree with the track. The SQL only
 * narrows candidates (LIKE patterns within D1's 50-byte limit); sameTitle,
 * sameArtist, and the duration decide in JS. With an artist word to filter on,
 * the scan walks artists (far fewer rows than songs) and reaches their songs
 * through songs_artist_idx. A D1 error is logged and treated as "no match" so
 * resolution can still continue on MusicBrainz.
 */
async function d1SongByText(title: string, artist: string, durationMs?: number): Promise<Song | undefined> {
  const titlePattern = likePattern(cleanTitle(title));
  if (!titlePattern) return undefined;
  const artistPattern = artistLikePattern(artist);
  try {
    const rows = artistPattern
      ? await all<Row>(
        `select s.*, a.name as artist_name from artists a cross join songs s on s.artist_id = a.id
         where a.name like ?1 and s.name like ?2 order by (s.album_id is null), s.created_at limit 100`,
        artistPattern, titlePattern,
      )
      : await all<Row>(
        `select s.*, a.name as artist_name from songs s join artists a on a.id = s.artist_id
         where s.name like ?1 order by (s.album_id is null), s.created_at limit 100`,
        titlePattern,
      );
    const row = rows.find((candidate) =>
      sameTitle(String(candidate.name), title) &&
      sameArtist(artist, String(candidate.artist_name)) &&
      durationAgrees(Number(candidate.duration_ms) || undefined, durationMs));
    return row ? songFromRow(row) : undefined;
  } catch (error) {
    console.warn('Resonote resolve: D1 text lookup failed', error);
    return undefined;
  }
}

interface CacheRow { songId: string; confidence: 'exact' | 'strong' }

async function readCache(keys: string[]): Promise<Map<string, CacheRow>> {
  if (!keys.length) return new Map();
  const rows = await allIn<Row>((list) => `select key, song_id, confidence from track_resolutions where key in (${list})`, keys);
  return new Map(rows.map((row) => [String(row.key), { songId: String(row.song_id), confidence: row.confidence === 'exact' ? 'exact' : 'strong' }]));
}

/**
 * Stores verified keys. A `text:` key is never stored as exact (it carries no
 * recording identity), and a weaker match never overwrites an exact row.
 */
function cacheWrites(keys: VerifiedKey[], songId: string): Statement[] {
  const unique = new Map<string, VerifiedKey['confidence']>();
  for (const { key, confidence } of keys) {
    const capped = key.startsWith('text:') ? 'strong' : confidence;
    if (unique.get(key) !== 'exact') unique.set(key, capped);
  }
  return [...unique].map(([key, confidence]) => sql(
    `insert into track_resolutions (key, song_id, confidence) values (?, ?, ?)
     on conflict(key) do update set song_id = excluded.song_id, confidence = excluded.confidence, created_at = datetime('now')
     where track_resolutions.confidence <> 'exact' or excluded.confidence = 'exact'`,
    key, songId, confidence,
  ));
}

async function loadSongAndArtistName(songId: string): Promise<{ song: Song; artistName?: string } | undefined> {
  const song = await loadEntity('song', songId);
  if (song?.kind !== 'song') return undefined;
  const artist = await loadEntity('artist', song.artistId);
  return { song, artistName: artist?.name };
}

// --- MusicBrainz ---

function isDeadline(error: unknown): boolean {
  return error instanceof MusicBrainzDeadlineError;
}

/**
 * Turns a MusicBrainz recording into a catalog song: an existing D1 import, the
 * seeded song it duplicates, or a fresh import through the /api/music/import path.
 */
async function songForRecording(recordingId: string, deadline: number, partial?: MbRecording): Promise<{ song: Song; genres: Map<string, MbGenre[]> } | { recording?: MbRecording }> {
  const existing = await d1SongByRecording(recordingId);
  if (existing) return { song: existing, genres: new Map() };
  if (partial) {
    const seeded = seedSongForRecording(partial);
    if (seeded) return { song: seeded, genres: new Map() };
  }
  let payload: Record<string, unknown> | undefined;
  try {
    payload = await fetchRecording(recordingId, deadline);
    const recording = payload as unknown as MbRecording;
    const seeded = seedSongForRecording(recording);
    if (seeded) return { song: seeded, genres: new Map([[seeded.id, recording.genres ?? []]]) };
    const onAlbum = await d1AlbumTrackForRecording(recording);
    if (onAlbum) return { song: onAlbum, genres: new Map([[onAlbum.id, recording.genres ?? []]]) };
    const genres = new Map<string, MbGenre[]>();
    const bundle = await resolveImport('song', recordingId, { recording: payload, genres, deadline });
    await upsertImportedCatalog({ artists: bundle.artists, albums: bundle.albums, songs: bundle.songs });
    const stored = await first<Row>('select * from songs where id = ?', bundle.focusId);
    if (stored) return { song: songFromRow(stored), genres };
    return { recording };
  } catch (error) {
    if (!isDeadline(error)) console.warn('Resonote resolve: import failed', recordingId, error);
    return { recording: (payload as unknown as MbRecording | undefined) ?? partial };
  }
}

async function attemptNetwork(track: NowPlayingTrack, deadline: number): Promise<Attempt> {
  const candidates: MbRecording[] = [];

  // 1. A recording id from the source (ListenBrainz, Last.fm). MusicBrainz confirms it or the import fails.
  if (track.mbid) {
    const outcome = await songForRecording(track.mbid, deadline);
    if ('song' in outcome) {
      return { match: { song: outcome.song, confidence: 'exact', fromCache: false, musicbrainzGenres: outcome.genres, verifiedKeys: [{ key: mbidKey(track.mbid), confidence: 'exact' }] }, candidates };
    }
    if (outcome.recording) candidates.push(outcome.recording);
  }

  // 2. ISRC (Apple Music, Spotify). MusicBrainz lists which recordings carry it.
  if (track.isrc && Date.now() < deadline) {
    try {
      const recordings = await lookupIsrc(track.isrc, deadline);
      const picked = pickIsrcRecording(track, recordings);
      if (picked) {
        const outcome = await songForRecording(picked.id, deadline, picked);
        if ('song' in outcome) {
          const verifiedKeys: VerifiedKey[] = [{ key: isrcKey(track.isrc), confidence: 'exact' }, { key: mbidKey(picked.id), confidence: 'exact' }];
          return { match: { song: outcome.song, confidence: 'exact', fromCache: false, musicbrainzGenres: outcome.genres, verifiedKeys }, candidates };
        }
        candidates.push(outcome.recording ?? picked);
      }
    } catch (error) {
      if (!isDeadline(error)) console.warn('Resonote resolve: ISRC lookup failed', track.isrc, error);
    }
  }

  // 3. Fielded search scored by title, artist, and duration. A popular title has
  // dozens of same-scored recordings (compilations, DJ mixes); with a duration,
  // the length window finds the album recording first, and the open query reads
  // up to 100 hits so it is not cut off after the first 25.
  if (!track.title || Date.now() >= deadline) return { candidates };
  let recordings: MbRecording[] = [];
  try {
    const timed = track.durationMs ? recordingSearchQuery(track.title, track.artist, track.durationMs) : null;
    if (timed) recordings = await searchRecordings(timed, 25, deadline);
    if (classifyCandidate(rankRecordings(track, recordings)[0]) !== 'strong' && Date.now() < deadline) {
      const open = recordingSearchQuery(track.title, track.artist);
      const more = open ? await searchRecordings(open, 100, deadline) : [];
      const seen = new Set(recordings.map((recording) => recording.id));
      recordings = [...recordings, ...more.filter((recording) => !seen.has(recording.id))];
    }
    const fallback = recordings.length ? null : fallbackSearchQuery(track.title, track.artist, track.durationMs);
    if (fallback && Date.now() < deadline) recordings = await searchRecordings(fallback, 10, deadline);
  } catch (error) {
    if (!isDeadline(error)) console.warn('Resonote resolve: search failed', error);
    if (!recordings.length) return { candidates };
  }
  const ranked = rankRecordings(track, recordings);
  const best = ranked[0];
  if (classifyCandidate(best) === 'strong') {
    const outcome = await songForRecording(best.recording.id, deadline, best.recording);
    if ('song' in outcome) {
      // The recording id is verified (MusicBrainz resolved it); the text key is added by the caller.
      const verifiedKeys: VerifiedKey[] = [{ key: mbidKey(best.recording.id), confidence: 'exact' }];
      return { match: { song: outcome.song, confidence: 'strong', fromCache: false, musicbrainzGenres: outcome.genres, verifiedKeys }, candidates };
    }
  }
  for (const candidate of ranked) {
    if (!candidates.some((recording) => recording.id === candidate.recording.id)) candidates.push(candidate.recording);
  }
  return { candidates };
}

// --- Genres ---

/**
 * Maps MusicBrainz genres onto genre ids a listener can assert: a seeded genre
 * with the same name, a D1 genre with the same MusicBrainz id or slug, or a new
 * D1 row (id `mb-genre-<mbid>`, unique slug). Returns the mapping plus the
 * inserts to run, so the caller can write them in one batch with its own rows.
 * The new rows' ids are deterministic; one that a concurrent request created
 * first (`insert or ignore`) has the same id.
 */
async function planGenres(incoming: Array<{ id: string; name: string }>): Promise<{ mapped: Map<string, Genre>; inserts: Statement[] }> {
  const mapped = new Map<string, Genre>();
  const pending = incoming.filter((genre) => {
    const local = [...seed.genres.values()].find((candidate) => fold(candidate.name) === fold(genre.name));
    if (local) mapped.set(genre.id, local);
    return !local;
  });
  if (!pending.length) return { mapped, inserts: [] };

  const slugs = pending.map((genre) => slugify(genre.name) || genre.id.slice(0, 8));
  const [byMbid, bySlug] = await Promise.all([
    allIn<Row>((list) => `select * from genres where musicbrainz_id in (${list})`, pending.map((genre) => genre.id)),
    allIn<Row>((list) => `select * from genres where slug in (${list})`, slugs.flatMap((slug) => [slug, `${slug}-mb`])),
  ]);
  const takenSlugs = new Set([...seed.genres.values()].map((genre) => genre.slug));
  for (const row of bySlug) takenSlugs.add(String(row.slug));

  const inserts: Statement[] = [];
  pending.forEach((genre, index) => {
    const existing = byMbid.find((row) => row.musicbrainz_id === genre.id)
      ?? bySlug.find((row) => row.slug === slugs[index] && !row.musicbrainz_id);
    if (existing) {
      mapped.set(genre.id, genreFromRow(existing));
      return;
    }
    let slug = slugs[index];
    if (takenSlugs.has(slug)) slug = `${slug}-mb`;
    if (takenSlugs.has(slug)) slug = `${slugs[index]}-${genre.id.slice(0, 8)}`;
    takenSlugs.add(slug);
    const created: Genre = { id: `mb-genre-${genre.id}`, kind: 'genre', name: genreDisplayName(genre.name), slug, musicbrainzId: genre.id };
    mapped.set(genre.id, created);
    // `insert or ignore`: a concurrent request may have created the same genre.
    inserts.push(sql('insert or ignore into genres (id, name, slug, musicbrainz_id) values (?, ?, ?, ?)', created.id, created.name, created.slug, genre.id));
  });
  return { mapped, inserts };
}

type StoredMbGenres = Array<{ id: string; count: number }>;

/**
 * MusicBrainz genres for the song, its album, and its artist (in that order),
 * fetched at most once per entity and remembered in entity_musicbrainz_genres.
 * A subject without a stored row is asked again on a later resolution (an
 * earlier attempt may have run out of time or hit a MusicBrainz error), always
 * within `deadline`. Stops as soon as `needed` genres are known.
 */
async function musicbrainzGenreSuggestions(
  subjects: Array<{ kind: 'song' | 'album' | 'artist'; id: string; mbid?: string }>,
  inHand: Map<string, MbGenre[]>,
  known: Set<string>,
  needed: number,
  deadline: number,
): Promise<WeightedGenre[]> {
  const stored = await allIn<Row>((list) => `select entity_id, genres from entity_musicbrainz_genres where entity_id in (${list})`, subjects.map((subject) => subject.id));
  const remembered = new Map(stored.map((row) => [String(row.entity_id), parseJson<StoredMbGenres>(row.genres, [])]));
  const collected: StoredMbGenres = [];
  const resource = { song: 'recording', album: 'release-group', artist: 'artist' } as const;

  for (const subject of subjects) {
    // Enough new genres beyond the ones Resonote already knows about? Stop asking.
    if (new Set(collected.map((genre) => genre.id).filter((id) => !known.has(id))).size >= needed) break;
    let list = remembered.get(subject.id);
    if (!list) {
      let raw = inHand.get(subject.id);
      if (!raw && subject.mbid && Date.now() < deadline) {
        try {
          raw = await fetchGenres(resource[subject.kind], subject.mbid, deadline);
        } catch (error) {
          if (!isDeadline(error)) console.warn('Resonote resolve: genre lookup failed', subject.mbid, error);
        }
      }
      if (!raw) continue;
      const top = topGenres(raw);
      const { mapped, inserts } = await planGenres(top);
      list = top.flatMap((genre) => (mapped.get(genre.id) ? [{ id: mapped.get(genre.id)!.id, count: genre.count }] : []));
      // The new genres and the remembered mapping land together, in one round trip.
      await batch([
        ...inserts,
        sql(
          `insert into entity_musicbrainz_genres (entity_id, entity_kind, genres) values (?, ?, ?)
           on conflict(entity_id) do update set genres = excluded.genres, fetched_at = datetime('now')`,
          subject.id, subject.kind, JSON.stringify(list),
        ),
      ]);
    }
    collected.push(...list);
  }

  const genres = new Map<string, Genre>();
  const ids = [...new Set(collected.map((genre) => genre.id))];
  for (const id of ids) {
    const local = seed.genres.get(id);
    if (local) genres.set(id, local);
  }
  const rows = await allIn<Row>((list) => `select * from genres where id in (${list})`, ids.filter((id) => !genres.has(id)));
  for (const row of rows) genres.set(String(row.id), genreFromRow(row));
  return collected.flatMap((genre) => {
    const found = genres.get(genre.id);
    return found ? [{ id: found.id, name: found.name, source: 'musicbrainz', votes: genre.count }] : [];
  });
}

// --- Suggestions ---

/** A cached answer should stay fast: genre lookups it still owes get this much time at most. */
const CACHED_GENRE_BUDGET_MS = 4_000;

async function buildSuggestions(input: {
  userId: string;
  song?: Song;
  album?: Album;
  artist?: Artist;
  match?: Match;
  seedText: string;
  deadline: number;
}): Promise<{ suggestions: ResolveResult['suggestions']; entriesCount: number }> {
  const { userId, song, album, artist } = input;
  const subjectIds = [song?.id, album?.id, artist?.id].filter((id): id is string => Boolean(id));

  const [tagMap, lensRows, listenRows, wrote, listened, count] = await Promise.all([
    genresForEntities(subjectIds, null),
    allIn<Row>((list) => `select lenses from journal_entries where is_public = 1 and entity_id in (${list}) limit 500`, subjectIds),
    // Moods come only from the caller's own listens; nobody else's private log is read.
    all<Row>('select song_id, moods from listen_logs where profile_id = ? order by listened_at desc limit 500', userId),
    song ? first('select 1 as hit from journal_entries where profile_id = ? and entity_id = ? limit 1', userId, song.id) : Promise.resolve(null),
    song ? first('select 1 as hit from listen_logs where profile_id = ? and song_id = ? limit 1', userId, song.id) : Promise.resolve(null),
    song ? first<{ n: number }>('select count(*) as n from journal_entries where entity_id = ? and is_public = 1', song.id) : Promise.resolve(null),
  ]);

  const levels: WeightedGenre[][] = subjectIds.map((id) => (tagMap.get(id) ?? []).map((tag) => ({ id: tag.genre.id, name: tag.genre.name, source: tag.source, votes: tag.votes })));
  const localIds = new Set(levels.flat().map((genre) => genre.id));
  let musicbrainz: WeightedGenre[] = [];
  if (song && localIds.size < MAX_SUGGESTED_GENRES) {
    musicbrainz = await musicbrainzGenreSuggestions(
      [
        { kind: 'song', id: song.id, mbid: song.musicbrainzId },
        ...(album ? [{ kind: 'album' as const, id: album.id, mbid: album.musicbrainzId }] : []),
        ...(artist ? [{ kind: 'artist' as const, id: artist.id, mbid: artist.musicbrainzId }] : []),
      ],
      input.match?.musicbrainzGenres ?? new Map(),
      localIds,
      MAX_SUGGESTED_GENRES - localIds.size,
      input.match?.fromCache ? Math.min(input.deadline, Date.now() + CACHED_GENRE_BUDGET_MS) : input.deadline,
    );
  }

  const parse = (value: unknown) => parseJson<unknown[]>(value, []);
  return {
    suggestions: {
      genres: orderGenreSuggestions(levels, musicbrainz, MAX_SUGGESTED_GENRES),
      lenses: rankLenses(lensRows.map((row) => parse(row.lenses))),
      moods: rankMoods(listenRows.map((row) => ({ songId: String(row.song_id), moods: parse(row.moods) })), song?.id),
      prompt: pickPrompt({ wroteBefore: Boolean(wrote), listenedBefore: Boolean(listened), seed: song?.id ?? input.seedText }),
    },
    entriesCount: Number(count?.n ?? 0),
  };
}

// --- Entry points ---

/** What the server itself read from a provider (resolveLink); never set from a client body. */
interface LinkContext {
  /** `url:<canonical link>`: the link the server fetched metadata for. */
  key: string;
  /**
   * Provider ids the server read from the provider. Only these may be stored on
   * a shared song row, and only when the match is certain (see storeProviderIds).
   */
  trusted: Pick<NowPlayingTrack, 'spotifyId' | 'youtubeId'>;
}

/**
 * Finds the catalog song for a track. Identifier lookups come first and win
 * over text: cached ids (each re-checked against the track's title and artist),
 * then a D1 song with the recording id, then the `text:` cache (re-checked
 * against the duration), then seed/D1 text, then MusicBrainz.
 */
async function matchTrack(track: NowPlayingTrack, deadline: number): Promise<{ match?: Match; attempt: Attempt }> {
  const keys = resolutionKeys(track);
  const cache = await readCache(keys);

  // 1. Cached identifiers, most trustworthy first.
  for (const key of keys.filter((candidate) => !candidate.startsWith('text:')).sort((a, b) => keyRank(a) - keyRank(b))) {
    const row = cache.get(key);
    if (!row) continue;
    const found = await loadSongAndArtistName(row.songId);
    // A row that names a different song than the source describes is not reused.
    if (found && trackPlausiblyIs(track, found.song, found.artistName)) {
      return { match: { song: found.song, confidence: row.confidence, fromCache: true, verifiedKeys: [] }, attempt: { candidates: [] } };
    }
  }

  // 2. A D1 song imported from this recording.
  if (track.mbid) {
    const song = await d1SongByRecording(track.mbid);
    if (song) return { match: { song, confidence: 'exact', fromCache: false, verifiedKeys: [{ key: mbidKey(track.mbid), confidence: 'exact' }] }, attempt: { candidates: [] } };
  }

  // 3. The text cache, as long as the durations still agree.
  const text = textKey(track);
  const textRow = text ? cache.get(text) : undefined;
  if (textRow) {
    const song = await loadEntity('song', textRow.songId);
    if (song?.kind === 'song' && durationAgrees(song.durationMs, track.durationMs)) {
      return { match: { song, confidence: 'strong', fromCache: true, verifiedKeys: [] }, attempt: { candidates: [] } };
    }
  }

  // 4. Seed catalog, then D1, by normalized artist and title.
  if (track.title && track.artist) {
    const song = seedSongByText(track.title, track.artist, track.durationMs) ?? await d1SongByText(track.title, track.artist, track.durationMs);
    if (song) return { match: { song, confidence: 'strong', fromCache: false, verifiedKeys: [] }, attempt: { candidates: [] } };
  }

  // 5. MusicBrainz.
  const attempt = await attemptNetwork(track, deadline);
  return { match: attempt.match, attempt };
}

/**
 * Stores provider ids the server read itself on an imported song, so the web
 * player can open it. Only for a certain match: exact, or strong with lengths
 * within 5 s. Never for seeded songs, never over an id already set, and never
 * from a client-sent track.
 */
function providerIdWrite(song: Song, track: NowPlayingTrack, match: Match, trusted: LinkContext['trusted'] | undefined): Statement | undefined {
  if (!trusted || seed.songs.has(song.id)) return undefined;
  const certain = match.confidence === 'exact' || durationCloseness(song.durationMs, track.durationMs) === 'strong';
  if (!certain) return undefined;
  const spotifyId = !song.spotifyId ? trusted.spotifyId : undefined;
  const youtubeId = !song.youtubeId ? trusted.youtubeId : undefined;
  if (!spotifyId && !youtubeId) return undefined;
  match.song = { ...song, spotifyId: song.spotifyId ?? spotifyId, youtubeId: song.youtubeId ?? youtubeId };
  return sql('update songs set spotify_id = coalesce(spotify_id, ?), youtube_id = coalesce(youtube_id, ?) where id = ?', spotifyId ?? null, youtubeId ?? null, song.id);
}

async function finishResolution(track: NowPlayingTrack, userId: string, deadline: number, match: Match | undefined, attempt: Attempt, link?: LinkContext): Promise<ResolveResult> {
  let album: Album | undefined;
  let artist: Artist | undefined;
  if (match) {
    const song = match.song;
    [album, artist] = await Promise.all([
      song.albumId ? loadEntity('album', song.albumId) as Promise<Album | undefined> : Promise.resolve(undefined),
      loadEntity('artist', song.artistId) as Promise<Artist | undefined>,
    ]);
    // A cache hit has nothing new to prove, except a link the server just read.
    const keys = match.fromCache ? [] : [...match.verifiedKeys];
    // The text key, when the source's own title and artist name this song.
    const text = textKey(track);
    if (!match.fromCache && text && trackNamesSong(track, song, artist?.name)) keys.push({ key: text, confidence: 'strong' });
    // The link the server read itself maps to whatever its metadata matched.
    if (link) keys.push({ key: link.key, confidence: match.confidence });
    const providerIds = providerIdWrite(song, track, match, link?.trusted);
    await batch([...cacheWrites(keys, song.id), ...(providerIds ? [providerIds] : [])]);
    // Fill gaps in what the source reported from the catalog.
    track.title ||= song.name;
    track.artist ||= artist?.name ?? '';
    track.album ??= album?.name;
    track.artworkURL ??= album?.imageUrl ?? artist?.imageUrl;
  }

  const confidence: Confidence = match ? match.confidence : attempt.candidates.length ? 'weak' : 'none';
  const { suggestions, entriesCount } = await buildSuggestions({
    userId,
    song: match?.song,
    album,
    artist,
    match,
    seedText: matchKey(track.artist, track.title),
    deadline,
  });

  return {
    ok: true,
    track,
    ...(match ? { song: match.song } : {}),
    ...(album ? { album } : {}),
    ...(artist ? { artist } : {}),
    confidence,
    candidates: match ? [] : attempt.candidates.slice(0, 5).map(recordingToSearchResult),
    suggestions,
    entriesCount,
  };
}

/**
 * Resolves a track from any now-playing source. Everything in `input` is
 * client-reported: its ids help find a song but are cached or stored only when
 * the server verified them (see Match.verifiedKeys and providerIdWrite).
 */
export async function resolveTrack(input: NowPlayingTrack, userId: string, link?: LinkContext): Promise<ResolveResult> {
  const deadline = Date.now() + MUSICBRAINZ_BUDGET_MS;
  const track: NowPlayingTrack = { ...input };
  const { match, attempt } = await matchTrack(track, deadline);
  return finishResolution(track, userId, deadline, match, attempt, link);
}

/** Resolves a shared Spotify / Apple Music / YouTube / song.link URL. */
export async function resolveLink(url: string, userId: string): Promise<ResolveResult> {
  const link: ParsedLink = parseMusicLink(url);
  const urlKey = `url:${link.canonicalUrl}`;
  const now = new Date().toISOString();
  const linkIds = {
    ...(link.platform === 'spotify' ? { spotifyId: link.id } : {}),
    ...(link.platform === 'apple-music' ? { appleMusicId: link.id } : {}),
    ...(link.platform === 'youtube' || link.platform === 'youtube-music' ? { youtubeId: link.id } : {}),
  };

  // A link resolved before needs no provider round trip at all. Link keys are
  // written only here, after the server read the provider's own metadata.
  const cached = (await readCache([urlKey])).get(urlKey);
  if (cached) {
    const found = await loadSongAndArtistName(cached.songId);
    if (found) {
      const deadline = Date.now() + MUSICBRAINZ_BUDGET_MS;
      const track: NowPlayingTrack = {
        title: found.song.name,
        artist: found.artistName ?? '',
        durationMs: found.song.durationMs,
        ...linkIds,
        url: link.openUrl,
        source: 'link',
        isPlaying: false,
        observedAt: now,
      };
      return finishResolution(track, userId, deadline, { song: found.song, confidence: cached.confidence, fromCache: true, verifiedKeys: [] }, { candidates: [] });
    }
  }

  const metadata = await fetchLinkMetadata(link);
  if (!metadata?.title) throw new LinkUnreadableError('That link could not be read right now. Try again, or search for the song.');
  return resolveTrack({
    title: metadata.title,
    artist: metadata.artist,
    album: metadata.album,
    durationMs: metadata.durationMs,
    artworkURL: metadata.artworkURL,
    isrc: metadata.isrc,
    spotifyId: metadata.spotifyId,
    appleMusicId: metadata.appleMusicId,
    youtubeId: metadata.youtubeId,
    url: link.openUrl,
    source: 'link',
    isPlaying: false,
    observedAt: now,
  }, userId, {
    key: urlKey,
    trusted: {
      spotifyId: metadata.spotifyId,
      // Anyone can upload a video titled after a song; only YouTube's auto-generated
      // "Artist - Topic" uploads (or ids from song.link's cross-platform data) are label releases.
      youtubeId: link.platform === 'youtube' || link.platform === 'youtube-music' ? (metadata.officialAudio ? metadata.youtubeId : undefined) : metadata.youtubeId,
    },
  });
}
