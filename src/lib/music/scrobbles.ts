// Pure mapping from scrobbling services onto NowPlayingTrack (the shape in
// ios/.../NowPlaying/NowPlayingTrack.swift). Fetching lives in now-playing.ts.
import { parseMusicLink } from '@/lib/music/links';
import { matchKey } from '@/lib/music/text';

export type NowPlayingSource = 'apple-music' | 'spotify' | 'lastfm' | 'listenbrainz' | 'shazam' | 'link' | 'manual';
export const NOW_PLAYING_SOURCES: NowPlayingSource[] = ['apple-music', 'spotify', 'lastfm', 'listenbrainz', 'shazam', 'link', 'manual'];

export interface NowPlayingTrack {
  title: string;
  artist: string;
  album?: string;
  durationMs?: number;
  artworkURL?: string;
  isrc?: string;
  mbid?: string;
  spotifyId?: string;
  appleMusicId?: string;
  youtubeId?: string;
  url?: string;
  source: NowPlayingSource;
  isPlaying: boolean;
  observedAt: string;
}

/** A finished listen older than this is history, not "now playing". */
export const RECENT_WINDOW_MS = 10 * 60_000;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ISRC = /^[A-Z]{2}[A-Z0-9]{3}\d{7}$/;

function text(value: unknown, max = 500): string | undefined {
  return typeof value === 'string' && value.trim() ? value.trim().slice(0, max) : undefined;
}

function positiveInt(value: unknown): number | undefined {
  const parsed = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? Math.round(parsed) : undefined;
}

export function normalizeIsrc(value: unknown): string | undefined {
  const candidate = typeof value === 'string' ? value.replace(/[-\s]/g, '').toUpperCase() : '';
  return ISRC.test(candidate) ? candidate : undefined;
}

export function normalizeMbid(value: unknown): string | undefined {
  return typeof value === 'string' && UUID.test(value.trim()) ? value.trim().toLowerCase() : undefined;
}

// Last.fm usernames: 2–15 characters starting with a letter (capped at 64 here).
export function isValidLastfmUser(value: string): boolean {
  return /^[A-Za-z][A-Za-z0-9_-]{1,63}$/.test(value);
}

// ListenBrainz uses MusicBrainz usernames, which may hold almost anything,
// including "@" (some people signed up with their email address). Only "/" (a
// path separator in the API URL), control or format characters, and the dot
// segments "." and ".." (which a URL would resolve away) are refused; the name
// is percent-encoded into the request path. MusicBrainz caps names at 64.
const LISTENBRAINZ_FORBIDDEN = new RegExp('[/\\p{Cc}\\p{Cf}]', 'u');

export function isValidListenBrainzUser(value: string): boolean {
  return value.length >= 1 && value.length <= 64 && !LISTENBRAINZ_FORBIDDEN.test(value) && value.trim() === value && value !== '.' && value !== '..';
}

/** Last.fm's grey star placeholder is not artwork. */
const LASTFM_PLACEHOLDER = '2a96cbd8b46e442fc41c2b86b821562f';
const LASTFM_SIZES = ['small', 'medium', 'large', 'extralarge', 'mega'];

function lastfmImage(images: unknown): string | undefined {
  const list = Array.isArray(images) ? images as Array<{ size?: string; '#text'?: string }> : [];
  return list
    .filter((image) => text(image['#text']) && !String(image['#text']).includes(LASTFM_PLACEHOLDER))
    .sort((a, b) => LASTFM_SIZES.indexOf(b.size ?? '') - LASTFM_SIZES.indexOf(a.size ?? ''))[0]?.['#text'];
}

/**
 * `user.getRecentTracks` (format=json) as a list, newest first, with no time
 * window. The first track carries `@attr.nowplaying = "true"` while something
 * is playing; finished scrobbles carry `date.uts` (a finished one without it is
 * skipped). Older API responses return a single track as an object.
 */
export function mapLastfmRecentList(payload: unknown, now = Date.now()): NowPlayingTrack[] {
  const recent = (payload as { recenttracks?: { track?: unknown } } | null)?.recenttracks;
  const raw = recent?.track;
  const tracks = (Array.isArray(raw) ? raw : raw ? [raw] : []) as Array<Record<string, unknown>>;
  const mapped: NowPlayingTrack[] = [];
  for (const track of tracks) {
    const title = text(track.name);
    const artistField = track.artist as { '#text'?: string; name?: string } | string | undefined;
    const artist = typeof artistField === 'string' ? text(artistField) : text(artistField?.['#text']) ?? text(artistField?.name);
    if (!title || !artist) continue;
    const isPlaying = (track['@attr'] as { nowplaying?: string } | undefined)?.nowplaying === 'true';
    const uts = positiveInt((track.date as { uts?: string } | undefined)?.uts);
    if (!isPlaying && !uts) continue;
    const album = (track.album as { '#text'?: string } | undefined)?.['#text'];
    mapped.push({
      title,
      artist,
      album: text(album),
      artworkURL: lastfmImage(track.image),
      mbid: normalizeMbid(track.mbid),
      url: text(track.url, 2048),
      source: 'lastfm',
      isPlaying,
      observedAt: new Date(isPlaying || !uts ? now : uts * 1000).toISOString(),
    });
  }
  return mapped;
}

/** From one service's plays, newest first: the playing one, else the newest that finished within RECENT_WINDOW_MS. */
export function currentPlay(tracks: NowPlayingTrack[] | null | undefined, now = Date.now()): NowPlayingTrack | null {
  return tracks?.find((track) => track.isPlaying || now - Date.parse(track.observedAt) <= RECENT_WINDOW_MS) ?? null;
}

/** The playing track, else the newest scrobble that finished within RECENT_WINDOW_MS. */
export function mapLastfmRecentTracks(payload: unknown, now = Date.now()): NowPlayingTrack | null {
  return currentPlay(mapLastfmRecentList(payload, now), now);
}

function providerIds(urls: Array<string | undefined>): Pick<NowPlayingTrack, 'spotifyId' | 'appleMusicId' | 'youtubeId'> {
  const ids: Pick<NowPlayingTrack, 'spotifyId' | 'appleMusicId' | 'youtubeId'> = {};
  for (const url of urls) {
    if (!url) continue;
    try {
      const link = parseMusicLink(url, 1);
      if (link.platform === 'spotify') ids.spotifyId ??= link.id;
      else if (link.platform === 'apple-music') ids.appleMusicId ??= link.id;
      else if (link.platform === 'youtube' || link.platform === 'youtube-music') ids.youtubeId ??= link.id;
    } catch {
      // Not a provider Resonote can open.
    }
  }
  return ids;
}

/**
 * One ListenBrainz listen (from `playing-now` or `listens`). Uses
 * `track_metadata.additional_info` (recording_mbid, isrc, duration_ms,
 * spotify_id, origin_url, media_player) and the server-side `mbid_mapping`
 * (recording_mbid, cover art, and url_rels such as the Spotify link).
 */
export function mapListenBrainzListen(listen: unknown, options: { isPlaying: boolean; now?: number }): NowPlayingTrack | null {
  const now = options.now ?? Date.now();
  const record = listen as { listened_at?: number; track_metadata?: Record<string, unknown> } | null;
  const metadata = record?.track_metadata;
  if (!metadata) return null;
  const title = text(metadata.track_name);
  const artist = text(metadata.artist_name);
  if (!title || !artist) return null;
  const info = (metadata.additional_info as Record<string, unknown> | undefined) ?? {};
  const mapping = (metadata.mbid_mapping as Record<string, unknown> | undefined) ?? {};
  const durationMs = positiveInt(info.duration_ms) ?? (positiveInt(info.duration) ? positiveInt(info.duration)! * 1000 : undefined);
  const spotify = text(info.spotify_id, 2048);
  const origin = text(info.origin_url, 2048);
  const linked = ((mapping.url_rels as Array<{ url?: unknown }> | undefined) ?? []).map((rel) => text(rel.url, 2048));
  const ids = providerIds([spotify?.startsWith('http') ? spotify : spotify ? `https://open.spotify.com/track/${spotify}` : undefined, origin, ...linked]);
  const releaseMbid = normalizeMbid(mapping.caa_release_mbid);
  const caaId = positiveInt(mapping.caa_id);
  const releaseGroup = normalizeMbid(info.release_group_mbid ?? mapping.release_group_mbid);
  const artworkURL = releaseMbid && caaId
    ? `https://coverartarchive.org/release/${releaseMbid}/${caaId}-500.jpg`
    : releaseGroup ? `https://coverartarchive.org/release-group/${releaseGroup}/front-500` : undefined;
  const mediaPlayer = text(info.media_player)?.toLowerCase() ?? '';
  const listenedAt = positiveInt(record?.listened_at);
  return {
    title,
    artist,
    album: text(metadata.release_name),
    durationMs,
    artworkURL,
    isrc: normalizeIsrc(info.isrc),
    mbid: normalizeMbid(info.recording_mbid) ?? normalizeMbid(mapping.recording_mbid),
    ...ids,
    // media_player names the app that played it; prefer a link that opens there.
    url: (mediaPlayer.includes('spotify') && ids.spotifyId ? `https://open.spotify.com/track/${ids.spotifyId}` : undefined)
      ?? (mediaPlayer.includes('youtube') && ids.youtubeId ? `https://music.youtube.com/watch?v=${ids.youtubeId}` : undefined)
      ?? origin
      ?? (ids.spotifyId ? `https://open.spotify.com/track/${ids.spotifyId}` : undefined),
    source: 'listenbrainz',
    isPlaying: options.isPlaying,
    observedAt: new Date(options.isPlaying || !listenedAt ? now : listenedAt * 1000).toISOString(),
  };
}

/** `GET /1/user/<user>/playing-now` → the active track, if any. */
export function mapListenBrainzPlayingNow(payload: unknown, now = Date.now()): NowPlayingTrack | null {
  const listens = (payload as { payload?: { listens?: unknown[] } } | null)?.payload?.listens ?? [];
  return listens.length ? mapListenBrainzListen(listens[0], { isPlaying: true, now }) : null;
}

/** `GET /1/user/<user>/listens?count=1` → the latest listen when it finished within the window. */
export function mapListenBrainzRecent(payload: unknown, now = Date.now()): NowPlayingTrack | null {
  const listens = (payload as { payload?: { listens?: Array<{ listened_at?: number }> } } | null)?.payload?.listens ?? [];
  const latest = listens[0];
  const listenedAt = positiveInt(latest?.listened_at);
  if (!latest || !listenedAt || now - listenedAt * 1000 > RECENT_WINDOW_MS) return null;
  return mapListenBrainzListen(latest, { isPlaying: false, now });
}

/** `GET /1/user/<user>/listens?count=10` → every dated listen, newest first, with no time window. */
export function mapListenBrainzListens(payload: unknown, now = Date.now()): NowPlayingTrack[] {
  const listens = (payload as { payload?: { listens?: Array<{ listened_at?: number }> } } | null)?.payload?.listens ?? [];
  return listens
    .filter((listen) => positiveInt(listen?.listened_at))
    .map((listen) => mapListenBrainzListen(listen, { isPlaying: false, now }))
    .filter((track): track is NowPlayingTrack => Boolean(track));
}

/** How many plays `recent` carries. */
export const RECENT_LIMIT = 10;

const MERGED_FIELDS = ['mbid', 'isrc', 'spotifyId', 'appleMusicId', 'youtubeId', 'artworkURL', 'album', 'durationMs'] as const;

function sameSong(a: NowPlayingTrack, b: NowPlayingTrack): boolean {
  if (a.isrc && a.isrc === b.isrc) return true;
  const key = matchKey(a.artist, a.title);
  return !key.startsWith('|') && !key.endsWith('|') && key === matchKey(b.artist, b.title);
}

/** Two reports of one play: the same song, and both playing or less than RECENT_WINDOW_MS apart. */
function samePlay(a: NowPlayingTrack, b: NowPlayingTrack): boolean {
  if (!sameSong(a, b)) return false;
  return (a.isPlaying && b.isPlaying) || Math.abs(Date.parse(a.observedAt) - Date.parse(b.observedAt)) < RECENT_WINDOW_MS;
}

function playingThenNewest(a: NowPlayingTrack, b: NowPlayingTrack): number {
  return Number(b.isPlaying) - Number(a.isPlaying) || Date.parse(b.observedAt) - Date.parse(a.observedAt);
}

/**
 * `recent` for GET /api/now-playing: plays from every service merged into one
 * list, newest first, at most `limit` long. Reports of the same play from
 * different services collapse into the playing one, else the newer, which takes identifiers only the other
 * had. At most one row is playing, and it comes first: when two services both
 * report something playing, the most recent sample wins and a different song
 * from the other stays as an ordinary row.
 */
export function mergeRecentPlays(lists: Array<NowPlayingTrack[] | null | undefined>, limit = RECENT_LIMIT): NowPlayingTrack[] {
  const candidates = lists
    .flatMap((list, index) => (list ?? []).map((track) => ({ track, list: index })))
    .filter(({ track }) => !Number.isNaN(Date.parse(track.observedAt)));
  candidates.sort((a, b) => playingThenNewest(a.track, b.track));
  // `lists` records which services a row already holds a report from: one
  // service's list never reports the same play twice, so repeat listens of a
  // song within one list stay separate rows.
  const kept: Array<{ track: NowPlayingTrack; reported: NowPlayingTrack; lists: Set<number> }> = [];
  for (const { track: candidate, list } of candidates) {
    const match = kept.find((row) => !row.lists.has(list) && samePlay(row.reported, candidate));
    if (match) {
      match.lists.add(list);
      const fill = match.track as unknown as Record<string, unknown>;
      for (const field of MERGED_FIELDS) {
        if (fill[field] === undefined && candidate[field] !== undefined) fill[field] = candidate[field];
      }
      continue;
    }
    const playing = candidate.isPlaying && !kept.some((row) => row.track.isPlaying);
    kept.push({ track: { ...candidate, isPlaying: playing }, reported: candidate, lists: new Set([list]) });
  }
  return kept.map((row) => row.track).sort(playingThenNewest).slice(0, limit);
}

/** Prefers a track that is actively playing; otherwise the freshest observation. */
export function pickNowPlaying(tracks: Array<NowPlayingTrack | null | undefined>): NowPlayingTrack | null {
  const usable = tracks.filter((track): track is NowPlayingTrack => Boolean(track));
  usable.sort((a, b) => Number(b.isPlaying) - Number(a.isPlaying) || b.observedAt.localeCompare(a.observedAt));
  return usable[0] ?? null;
}

/**
 * Validates a client-sent NowPlayingTrack. Required strings must be present
 * (unless an mbid or ISRC identifies the recording); optional fields that fail
 * validation are dropped rather than failing the request.
 */
export function sanitizeTrack(input: unknown, now = Date.now()): NowPlayingTrack | null {
  if (!input || typeof input !== 'object') return null;
  const raw = input as Record<string, unknown>;
  const mbid = normalizeMbid(raw.mbid);
  const isrc = normalizeIsrc(raw.isrc);
  const title = text(raw.title, 300) ?? '';
  const artist = text(raw.artist, 300) ?? '';
  if ((!title || !artist) && !mbid && !isrc) return null;
  const source = NOW_PLAYING_SOURCES.includes(raw.source as NowPlayingSource) ? raw.source as NowPlayingSource : 'manual';
  const observed = typeof raw.observedAt === 'string' && !Number.isNaN(Date.parse(raw.observedAt)) ? raw.observedAt : new Date(now).toISOString();
  const url = text(raw.url, 2048);
  const artwork = text(raw.artworkURL, 2048);
  return {
    title,
    artist,
    album: text(raw.album, 300),
    durationMs: positiveInt(raw.durationMs),
    artworkURL: artwork && /^https?:\/\//i.test(artwork) ? artwork : undefined,
    isrc,
    mbid,
    spotifyId: typeof raw.spotifyId === 'string' && /^[A-Za-z0-9]{22}$/.test(raw.spotifyId) ? raw.spotifyId : undefined,
    appleMusicId: typeof raw.appleMusicId === 'string' && /^\d{1,15}$/.test(raw.appleMusicId) ? raw.appleMusicId : undefined,
    youtubeId: typeof raw.youtubeId === 'string' && /^[A-Za-z0-9_-]{11}$/.test(raw.youtubeId) ? raw.youtubeId : undefined,
    url: url && /^https?:\/\//i.test(url) ? url : undefined,
    source,
    isPlaying: raw.isPlaying === true,
    observedAt: observed,
  };
}
