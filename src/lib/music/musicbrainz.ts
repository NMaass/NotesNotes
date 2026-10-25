import 'server-only';
import { getCloudflareContext } from '@opennextjs/cloudflare';
import type { Album, Artist, SearchResult, Song } from '@/lib/data/types';
import { isAnthology, preferredRelease, type MbGenre, type MbRecording } from '@/lib/music/matching';
import { sameTitle } from '@/lib/music/text';
import { slugify } from '@/lib/utils';

const BASE = 'https://musicbrainz.org/ws/2';
let lastRequestAt = 0;

async function contactEmail(): Promise<string> {
  try {
    const { env } = await getCloudflareContext({ async: true });
    const bound = (env as Record<string, unknown>).MUSICBRAINZ_CONTACT_EMAIL;
    if (typeof bound === 'string' && bound) return bound;
  } catch {
    // Local dev without the proxy falls through to process.env below.
  }
  return process.env.MUSICBRAINZ_CONTACT_EMAIL ?? 'local-demo@example.invalid';
}

const TRANSIENT = new Set([502, 503, 504]);

/** Thrown instead of calling MusicBrainz when a caller's time budget has run out. */
export class MusicBrainzDeadlineError extends Error {
  constructor() {
    super('MusicBrainz is busy; try again in a moment.');
  }
}

// One request at a time per isolate, ≥1.05 s apart. Waiting callers are served
// earliest-deadline-first (callers without a deadline count as "20 s after they
// asked"), so when several now-playing lookups overlap the first one finishes
// instead of all of them interleaving and missing their budgets together.
// Each caller still performs its own fetch, in its own request context.
const NO_DEADLINE_SLACK_MS = 20_000;
interface Waiter { priority: number; order: number; grant: () => void }
const waiters: Waiter[] = [];
let busy = false;
let order = 0;

function releaseTurn() {
  waiters.sort((a, b) => a.priority - b.priority || a.order - b.order);
  const next = waiters.shift();
  if (next) next.grant();
  else busy = false;
}

async function acquireTurn(deadline?: number): Promise<void> {
  if (!busy) {
    busy = true;
    return;
  }
  await new Promise<void>((resolve, reject) => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const waiter: Waiter = {
      priority: deadline ?? Date.now() + NO_DEADLINE_SLACK_MS,
      order: order++,
      grant: () => {
        if (timer) clearTimeout(timer);
        resolve();
      },
    };
    // A caller whose budget runs out while waiting leaves the line without a request.
    if (deadline) {
      timer = setTimeout(() => {
        const index = waiters.indexOf(waiter);
        if (index < 0) return;
        waiters.splice(index, 1);
        reject(new MusicBrainzDeadlineError());
      }, Math.max(0, deadline - Date.now()));
    }
    waiters.push(waiter);
  });
}

async function throttledFetch(url: string, deadline?: number): Promise<Response> {
  await acquireTurn(deadline);
  try {
    const contact = await contactEmail();
    // MusicBrainz flakes occasionally (502/503/520). Keep the turn and retry
    // with backoff so one rough response never fails an import or a search.
    // Every wait checks the caller's deadline first: a caller whose budget is
    // gone gives the turn back at once instead of sleeping on it.
    const backoff = async (attempt: number) => {
      const delay = 2000 * (attempt + 1);
      if (deadline && Date.now() + delay > deadline) throw new MusicBrainzDeadlineError();
      await new Promise((resolve) => setTimeout(resolve, delay));
    };
    for (let attempt = 0; attempt < 4; attempt += 1) {
      const wait = Math.max(0, 1050 - (Date.now() - lastRequestAt));
      // Work whose caller already gave up must not spend the shared rate limit.
      if (deadline && Date.now() + wait > deadline) throw new MusicBrainzDeadlineError();
      if (wait) await new Promise((resolve) => setTimeout(resolve, wait));
      lastRequestAt = Date.now();
      let response: Response;
      try {
        response = await fetch(url, {
          headers: { Accept: 'application/json', 'User-Agent': `Resonote/0.1 (${contact})` },
          next: { revalidate: 60 * 60 * 24 },
          ...(deadline ? { signal: AbortSignal.timeout(Math.max(1000, deadline - Date.now())) } : {}),
        });
      } catch {
        // The abort at the deadline lands here too; that is the deadline, not a flaky network.
        if (deadline && Date.now() >= deadline) throw new MusicBrainzDeadlineError();
        if (attempt === 3) throw new Error('MusicBrainz is unreachable right now.');
        await backoff(attempt);
        continue;
      }
      if (TRANSIENT.has(response.status) && attempt < 3) {
        await backoff(attempt);
        continue;
      }
      return response;
    }
    throw new Error('MusicBrainz kept failing after retries.');
  } finally {
    releaseTurn();
  }
}

export async function searchMusicBrainz(query: string, kind: 'artist' | 'album' | 'song' = 'song'): Promise<SearchResult[]> {
  if (!query.trim()) return [];
  const resource = kind === 'album' ? 'release-group' : kind === 'song' ? 'recording' : 'artist';
  const url = `${BASE}/${resource}/?query=${encodeURIComponent(query)}&fmt=json&limit=6`;
  const response = await throttledFetch(url);
  if (!response.ok) throw new Error(`MusicBrainz returned ${response.status}`);
  const payload = await response.json() as Record<string, unknown>;

  if (kind === 'artist') {
    const items = (payload.artists as Array<Record<string, unknown>> | undefined) ?? [];
    return items.map((item) => {
      const entity: Artist = {
        id: `mb-artist-${item.id}`, kind: 'artist', name: String(item.name ?? 'Unknown artist'),
        slug: slugify(String(item.name ?? item.id)), musicbrainzId: String(item.id),
        country: item.country ? String(item.country) : undefined,
        summary: item.disambiguation ? String(item.disambiguation) : undefined
      };
      return { entity, subtitle: [entity.country, entity.summary, 'MusicBrainz'].filter(Boolean).join(' · '), source: 'musicbrainz' as const };
    });
  }

  if (kind === 'album') {
    const items = (payload['release-groups'] as Array<Record<string, unknown>> | undefined) ?? [];
    return items.map((item) => {
      const artistCredit = (item['artist-credit'] as Array<Record<string, unknown>> | undefined)?.[0];
      const artistName = artistCredit ? String(artistCredit.name ?? '') : '';
      const firstReleaseDate = String(item['first-release-date'] ?? '');
      const entity: Album = {
        id: `mb-album-${item.id}`, kind: 'album', name: String(item.title ?? 'Unknown album'),
        slug: slugify(String(item.title ?? item.id)), artistId: `remote-${slugify(artistName)}`,
        year: firstReleaseDate ? Number(firstReleaseDate.slice(0, 4)) : undefined,
        releaseGroupType: item['primary-type'] ? String(item['primary-type']) : undefined,
        musicbrainzId: String(item.id)
      };
      return { entity, subtitle: [artistName, entity.year, 'MusicBrainz'].filter(Boolean).join(' · '), source: 'musicbrainz' as const };
    });
  }

  const items = (payload.recordings as Array<Record<string, unknown>> | undefined) ?? [];
  return items.map((item) => {
    const artistCredit = (item['artist-credit'] as Array<Record<string, unknown>> | undefined)?.[0];
    const artistName = artistCredit ? String(artistCredit.name ?? '') : '';
    const releases = item.releases as Array<Record<string, unknown>> | undefined;
    const albumName = releases?.[0]?.title ? String(releases[0].title) : '';
    const entity: Song = {
      id: `mb-song-${item.id}`, kind: 'song', name: String(item.title ?? 'Unknown recording'),
      slug: slugify(String(item.title ?? item.id)), artistId: `remote-${slugify(artistName)}`,
      albumId: albumName ? `remote-${slugify(albumName)}` : undefined,
      durationMs: item.length ? Number(item.length) : undefined,
      musicbrainzId: String(item.id)
    };
    return { entity, subtitle: [artistName, albumName, 'MusicBrainz'].filter(Boolean).join(' · '), source: 'musicbrainz' as const };
  });
}

// --- Transactional import resolution ---
// Resolves a MusicBrainz entity into a complete artist/album/songs bundle so a
// remote discovery result can become a permanent journal target. Everything is
// resolved BEFORE anything is persisted, so a partial failure leaves no orphans.

interface MbCreditEntry { name?: string; joinphrase?: string; artist?: { id?: string; name?: string; 'sort-name'?: string } }
interface MbReleaseGroupRef { id?: string; title?: string; 'primary-type'?: string; 'secondary-types'?: string[] }
interface MbTrack {
  id?: string;
  title?: string;
  position?: number;
  length?: number;
  'artist-credit'?: MbCreditEntry[];
  recording?: { id?: string; title?: string; length?: number; 'artist-credit'?: MbCreditEntry[] };
}
interface MbMedia { 'track-count'?: number; tracks?: MbTrack[] }
interface MbRelease { id?: string; title?: string; status?: string; date?: string; media?: MbMedia[]; 'release-group'?: MbReleaseGroupRef }

/** Options shared by the import resolvers. */
export interface ImportOptions {
  /** A recording payload already fetched with `fetchRecording`, saving a request. */
  recording?: Record<string, unknown>;
  /** Receives MusicBrainz community genres per imported entity id, at no extra request. */
  genres?: Map<string, MbGenre[]>;
  /** Epoch ms after which no further MusicBrainz request is started. */
  deadline?: number;
}

export interface ImportBundle {
  artists: Artist[];
  albums: Album[];
  songs: Song[];
  focusKind: 'artist' | 'album' | 'song';
  focusId: string;
}

async function fetchJsonOrThrow(url: string, deadline?: number): Promise<Record<string, unknown>> {
  const response = await throttledFetch(url, deadline);
  if (response.status === 404) throw new Error('MusicBrainz has no entry with that identifier.');
  if (!response.ok) throw new Error(`MusicBrainz returned ${response.status}`);
  return response.json() as Promise<Record<string, unknown>>;
}

function creditArtist(credit: MbCreditEntry | undefined): { id: string; name: string; sortName?: string } | undefined {
  const artist = credit?.artist;
  if (!artist?.id || !artist.name) return undefined;
  return { id: artist.id, name: artist.name, sortName: artist['sort-name'] ?? undefined };
}

function coverArt(rgId: string): string {
  return `https://coverartarchive.org/release-group/${rgId}/front-500`;
}

class ImportBuilder {
  readonly artists = new Map<string, Artist>();
  readonly albums = new Map<string, Album>();
  readonly songs = new Map<string, Song>();
  private usedAlbumSlugs = new Set<string>();
  private usedSongSlugs = new Set<string>();

  artist(credit: { id: string; name: string; sortName?: string; country?: string }): Artist {
    const id = `mb-artist-${credit.id}`;
    const existing = this.artists.get(id);
    if (existing) return existing;
    const artist: Artist = {
      id,
      kind: 'artist',
      name: credit.name,
      slug: slugify(credit.sortName || credit.name) || slugify(credit.id),
      sortName: credit.sortName,
      country: credit.country,
      musicbrainzId: credit.id,
    };
    this.artists.set(id, artist);
    return artist;
  }

  album(input: { rgId: string; title: string; artistId: string; year?: number; primaryType?: string }): Album {
    const id = `mb-album-${input.rgId}`;
    const existing = this.albums.get(id);
    if (existing) return existing;
    let slug = slugify(input.title) || input.rgId.slice(0, 8);
    while (this.usedAlbumSlugs.has(slug)) slug = `${slug}-${input.rgId.slice(0, 5)}`;
    this.usedAlbumSlugs.add(slug);
    const album: Album = {
      id,
      kind: 'album',
      name: input.title,
      slug,
      artistId: input.artistId,
      year: input.year,
      releaseGroupType: input.primaryType,
      musicbrainzId: input.rgId,
      imageUrl: coverArt(input.rgId),
    };
    this.albums.set(id, album);
    return album;
  }

  song(input: { recordingId: string; title: string; artistId: string; albumId?: string; trackNumber?: number; durationMs?: number }): Song {
    const id = `mb-song-${input.recordingId}`;
    const existing = this.songs.get(id);
    if (existing) {
      if (!existing.albumId && input.albumId) existing.albumId = input.albumId;
      if (!existing.trackNumber && input.trackNumber) existing.trackNumber = input.trackNumber;
      return existing;
    }
    let slug = slugify(input.title) || input.recordingId.slice(0, 8);
    while (this.usedSongSlugs.has(slug)) slug = `${slug}-${input.recordingId.slice(0, 5)}`;
    this.usedSongSlugs.add(slug);
    const song: Song = {
      id,
      kind: 'song',
      name: input.title,
      slug,
      artistId: input.artistId,
      albumId: input.albumId,
      trackNumber: input.trackNumber,
      durationMs: input.durationMs,
      musicbrainzId: input.recordingId,
    };
    this.songs.set(id, song);
    return song;
  }

  /** The focused song comes first in `songs`, so a client that takes the first song gets the one asked for. */
  bundle(focusKind: ImportBundle['focusKind'], focusId: string): ImportBundle {
    const songs = [...this.songs.values()];
    const focusIndex = focusKind === 'song' ? songs.findIndex((song) => song.id === focusId) : -1;
    if (focusIndex > 0) songs.unshift(...songs.splice(focusIndex, 1));
    return { artists: [...this.artists.values()], albums: [...this.albums.values()], songs, focusKind, focusId };
  }
}

/** The credited artist for one track: its own credit, then its recording's, then the release's. */
function trackArtist(builder: ImportBuilder, track: MbTrack, fallback: Artist): Artist {
  const credit = creditArtist(track['artist-credit']?.[0]) ?? creditArtist(track.recording?.['artist-credit']?.[0]);
  return credit ? builder.artist({ ...credit, country: undefined }) : fallback;
}

function rankReleases(releases: MbRelease[]): MbRelease[] {
  return [...releases].sort((a, b) => {
    const officialA = a.status === 'Official' ? 0 : 1;
    const officialB = b.status === 'Official' ? 0 : 1;
    if (officialA !== officialB) return officialA - officialB;
    const mediaA = a.media?.length ?? 9;
    const mediaB = b.media?.length ?? 9;
    if (mediaA !== mediaB) return mediaA - mediaB;
    return String(a.date ?? '9999').localeCompare(String(b.date ?? '9999'));
  });
}

/**
 * Imports a release group with its tracklist. With `onlyRecording` (a song
 * import that fell back to the whole group), an anthology contributes just that
 * recording's track, as in resolveReleaseInto.
 */
async function resolveReleaseGroupInto(builder: ImportBuilder, rgMbid: string, options: ImportOptions = {}, onlyRecording?: string): Promise<Album> {
  const { deadline } = options;
  const group = await fetchJsonOrThrow(`${BASE}/release-group/${encodeURIComponent(rgMbid)}?inc=artist-credits+genres&fmt=json`, deadline);
  const credit = creditArtist((group['artist-credit'] as MbCreditEntry[] | undefined)?.[0]);
  if (!credit) throw new Error('That release group has no resolvable artist credit.');
  const artist = builder.artist({ ...credit, country: undefined });
  const skipNeighbours = Boolean(onlyRecording) && isAnthology(group as MbReleaseGroupRef, credit.id);

  const listing = await fetchJsonOrThrow(`${BASE}/release?release-group=${encodeURIComponent(rgMbid)}&status=official&fmt=json&limit=25`, deadline);
  const candidates = rankReleases((listing.releases as MbRelease[] | undefined) ?? []).filter((release) => release.id).slice(0, 3);
  if (!candidates.length) throw new Error('No official release exists for this album yet.');

  // Browse listings omit media/tracklists, so probe candidates until one yields tracks.
  let album: Album | undefined;
  for (const candidate of candidates) {
    const detail = await fetchJsonOrThrow(`${BASE}/release/${encodeURIComponent(candidate.id!)}?inc=recordings+artist-credits+media&fmt=json`, deadline);
    const media = (detail.media as MbMedia[] | undefined) ?? [];
    const tracks = media.flatMap((medium) => medium.tracks ?? []).filter((track) => track.recording?.id);
    if (!tracks.length) continue;
    album = builder.album({
      rgId: rgMbid,
      title: String(group.title ?? candidate.title ?? 'Unknown album'),
      artistId: artist.id,
      year: Number(String(group['first-release-date'] ?? candidate.date ?? '').slice(0, 4)) || undefined,
      primaryType: group['primary-type'] ? String(group['primary-type']) : undefined,
    });
    for (const track of tracks) {
      const recording = track.recording!;
      if (skipNeighbours && recording.id !== onlyRecording) continue;
      builder.song({
        recordingId: recording.id!,
        title: track.title ?? recording.title ?? 'Unknown track',
        // Soundtracks, splits, and compilations credit each track to its own artist.
        artistId: trackArtist(builder, track, artist).id,
        albumId: album.id,
        trackNumber: track.position,
        durationMs: track.length ?? recording.length ?? undefined,
      });
    }
    break;
  }
  if (!album) throw new Error('No release of this album carries a linked tracklist on MusicBrainz.');
  options.genres?.set(album.id, (group.genres as MbGenre[] | undefined) ?? []);
  return album;
}

/**
 * A recording with everything import and suggestions need in one request:
 * artist credits, releases with their release groups (so the album can be
 * chosen without a per-release lookup), and community genres.
 */
export async function fetchRecording(mbid: string, deadline?: number): Promise<Record<string, unknown>> {
  return fetchJsonOrThrow(`${BASE}/recording/${encodeURIComponent(mbid)}?inc=artist-credits+releases+release-groups+genres&fmt=json`, deadline);
}

/**
 * Recordings carrying an ISRC (usually one; occasionally several mixes), with
 * their releases and release groups so the canonical recording can be told from
 * a copy that only one compilation uses. The `isrc` lookup's JSON leaves
 * releases out whatever `inc` says, so the recording search (`isrc:` field) is
 * asked first; the lookup (which still carries first-release dates) covers a
 * search index that has not caught up yet.
 */
export async function lookupIsrc(isrc: string, deadline?: number): Promise<MbRecording[]> {
  const found = await searchRecordings(`isrc:${isrc}`, 25, deadline);
  if (found.length) return found;
  const response = await throttledFetch(`${BASE}/isrc/${encodeURIComponent(isrc)}?inc=artist-credits&fmt=json`, deadline);
  if (response.status === 404) return [];
  if (!response.ok) throw new Error(`MusicBrainz returned ${response.status}`);
  const payload = await response.json() as { recordings?: MbRecording[] };
  return payload.recordings ?? [];
}

/** Raw recording search results for a Lucene query (see matching.ts). */
export async function searchRecordings(query: string, limit = 25, deadline?: number): Promise<MbRecording[]> {
  const response = await throttledFetch(`${BASE}/recording/?query=${encodeURIComponent(query)}&fmt=json&limit=${limit}`, deadline);
  if (!response.ok) throw new Error(`MusicBrainz returned ${response.status}`);
  const payload = await response.json() as { recordings?: MbRecording[] };
  return payload.recordings ?? [];
}

/** Community genres for one MusicBrainz entity. */
export async function fetchGenres(resource: 'recording' | 'release-group' | 'artist', mbid: string, deadline?: number): Promise<MbGenre[]> {
  const payload = await fetchJsonOrThrow(`${BASE}/${resource}/${encodeURIComponent(mbid)}?inc=genres&fmt=json`, deadline);
  return (payload.genres as MbGenre[] | undefined) ?? [];
}

/**
 * Builds the album from one release that contains the recording, in a single
 * request (tracklist, release group, and credits together). Returns undefined
 * when that release carries no linked tracklist.
 *
 * Each track keeps its own artist credit; the focused recording always takes
 * the recording's credit (`focus.artist`). From an anthology (a compilation,
 * DJ mix, or Various Artists release) only the focused track is imported: its
 * neighbours belong to other artists and other albums.
 */
async function resolveReleaseInto(builder: ImportBuilder, releaseId: string, options: ImportOptions, focus: { recordingId: string; artist: Artist }): Promise<Album | undefined> {
  const detail = await fetchJsonOrThrow(`${BASE}/release/${encodeURIComponent(releaseId)}?inc=recordings+artist-credits+media+release-groups&fmt=json`, options.deadline);
  const group = detail['release-group'] as (MbReleaseGroupRef & { 'first-release-date'?: string }) | undefined;
  const credit = creditArtist((detail['artist-credit'] as MbCreditEntry[] | undefined)?.[0]);
  const tracks = ((detail.media as MbMedia[] | undefined) ?? []).flatMap((medium) => medium.tracks ?? []).filter((track) => track.recording?.id);
  if (!group?.id || !credit || !tracks.length) return undefined;
  const anthology = isAnthology(group, credit.id);
  const releaseArtist = builder.artist({ ...credit, country: undefined });
  const album = builder.album({
    rgId: group.id,
    title: String(group.title ?? detail.title ?? 'Unknown album'),
    artistId: releaseArtist.id,
    year: Number(String(group['first-release-date'] ?? detail.date ?? '').slice(0, 4)) || undefined,
    primaryType: group['primary-type'] ? String(group['primary-type']) : undefined,
  });
  for (const track of tracks) {
    const recording = track.recording!;
    const focused = recording.id === focus.recordingId;
    if (anthology && !focused) continue;
    builder.song({
      recordingId: recording.id!,
      title: track.title ?? recording.title ?? 'Unknown track',
      artistId: focused ? focus.artist.id : trackArtist(builder, track, releaseArtist).id,
      albumId: album.id,
      trackNumber: track.position,
      durationMs: track.length ?? recording.length ?? undefined,
    });
  }
  return album;
}

export async function resolveImport(kind: 'artist' | 'album' | 'song', mbid: string, options: ImportOptions = {}): Promise<ImportBundle> {
  const { deadline } = options;
  if (kind === 'album') {
    const builder = new ImportBuilder();
    const album = await resolveReleaseGroupInto(builder, mbid, options);
    return builder.bundle('album', album.id);
  }

  if (kind === 'song') {
    const builder = new ImportBuilder();
    const recording = options.recording ?? await fetchRecording(mbid, deadline);
    const credit = creditArtist((recording['artist-credit'] as MbCreditEntry[] | undefined)?.[0]);
    if (!credit) throw new Error('That recording has no resolvable artist credit.');
    const artist = builder.artist({ ...credit, country: undefined });

    const releases = (recording.releases as MbRelease[] | undefined) ?? [];
    // Releases carry their release group, so pick the most canonical album
    // (official studio album over single, compilation, or live) directly.
    const preferred = preferredRelease(releases);
    let albumId: string | undefined;
    if (preferred?.id && preferred['release-group']?.id) {
      // Fast path: that release's own tracklist, one request.
      try {
        albumId = (await resolveReleaseInto(builder, preferred.id, options, { recordingId: mbid, artist }))?.id;
      } catch (error) {
        if (error instanceof MusicBrainzDeadlineError) throw error;
      }
    }
    let releaseGroup: { id?: string } | undefined = preferred?.['release-group'];
    const candidate = releases.find((release) => release.id);
    if (!albumId && !releaseGroup?.id && candidate?.id) {
      const releaseDetail = await fetchJsonOrThrow(`${BASE}/release/${encodeURIComponent(candidate.id)}?inc=release-groups&fmt=json`, deadline);
      releaseGroup = releaseDetail['release-group'] as MbReleaseGroupRef | undefined;
    }

    if (!albumId && releaseGroup?.id) {
      try {
        const album = await resolveReleaseGroupInto(builder, releaseGroup.id, options, mbid);
        albumId = album.id;
      } catch (error) {
        if (error instanceof MusicBrainzDeadlineError) throw error;
        albumId = undefined;
      }
    }

    const title = String(recording.title ?? 'Unknown recording');
    // The chosen pressing may carry a different recording of the same track
    // (another mix or master). Point at that album track instead of adding a
    // second, number-less copy of the song to the album.
    const albumTrack = albumId && !builder.songs.has(`mb-song-${mbid}`)
      ? [...builder.songs.values()].find((song) => song.albumId === albumId && sameTitle(song.name, title))
      : undefined;
    const focused = albumTrack ?? builder.song({
      recordingId: mbid,
      title,
      artistId: artist.id,
      albumId,
      durationMs: recording.length ? Number(recording.length) : undefined,
    });
    // The recording itself is always credited to the recording's artist, never a release's.
    if (focused.id === `mb-song-${mbid}`) focused.artistId = artist.id;
    // inc=genres also fills the credited artist's genres: no extra request for either.
    if (Array.isArray(recording.genres)) options.genres?.set(focused.id, recording.genres as MbGenre[]);
    const creditedGenres = (recording['artist-credit'] as Array<{ artist?: { genres?: MbGenre[] } }> | undefined)?.[0]?.artist?.genres;
    if (Array.isArray(creditedGenres)) options.genres?.set(artist.id, creditedGenres);
    return builder.bundle('song', focused.id);
  }

  const builder = new ImportBuilder();
  const payload = await fetchJsonOrThrow(`${BASE}/artist/${encodeURIComponent(mbid)}?inc=aliases&fmt=json`, deadline);
  if (!payload.id || !payload.name) throw new Error('MusicBrainz has no artist with that identifier.');
  const artist = builder.artist({
    id: String(payload.id),
    name: String(payload.name),
    sortName: payload['sort-name'] ? String(payload['sort-name']) : undefined,
    country: payload.country ? String(payload.country) : undefined,
  });
  return builder.bundle('artist', artist.id);
}
