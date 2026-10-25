// Pure MusicBrainz matching: query building, candidate scoring, and the shapes
// clients receive. No network here, so every rule is unit-testable.
import type { SearchResult, Song } from '@/lib/data/types';
import { slugify } from '@/lib/utils';
import { cleanTitle, fold, matchKey, normalizeSearch, primaryArtist, sameArtist, sameTitle, splitArtists } from '@/lib/music/text';

export type Confidence = 'exact' | 'strong' | 'weak' | 'none';

export interface MbArtistCredit { name?: string; joinphrase?: string; artist?: { id?: string; name?: string; 'sort-name'?: string } }
export interface MbReleaseGroup { id?: string; title?: string; 'primary-type'?: string | null; 'secondary-types'?: string[] | null }
export interface MbReleaseRef { id?: string; title?: string; status?: string | null; date?: string; 'release-group'?: MbReleaseGroup }
export interface MbGenre { id?: string; name?: string; count?: number }
export interface MbRecording {
  id: string;
  title?: string;
  length?: number | null;
  video?: boolean;
  disambiguation?: string;
  'first-release-date'?: string;
  'artist-credit'?: MbArtistCredit[];
  releases?: MbReleaseRef[];
  genres?: MbGenre[];
  score?: number;
}

/** Escapes text for use inside a quoted Lucene phrase. */
export function luceneQuote(value: string): string {
  return `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

/**
 * Fielded recording search. `NOT secondarytype:compilation` is deliberately
 * absent: the recording index matches ANY release, so it drops every studio
 * recording that was ever anthologized (verified live: it hides the canonical
 * "Lithium" and "Some Resolve" recordings). Compilations are ranked down instead.
 */
export function recordingSearchQuery(title: string, artist: string, durationMs?: number): string | null {
  const cleanedTitle = cleanTitle(title).trim();
  if (!cleanedTitle) return null;
  const parts = [`recording:${luceneQuote(cleanedTitle)}`];
  const credit = primaryArtist(artist).trim();
  if (credit) parts.push(`artist:${luceneQuote(credit)}`);
  parts.push('status:official', 'NOT secondarytype:live');
  // A popular song has dozens of same-titled recordings (compilations, DJ mixes)
  // that all score 100; the length window brings the album recording into reach.
  if (durationMs) parts.push(durationWindow(durationMs));
  return parts.join(' AND ');
}

/** Lucene range on recording length, as wide as a "strong" duration match. */
export function durationWindow(durationMs: number): string {
  return `dur:[${Math.max(0, durationMs - 5_000)} TO ${durationMs + 5_000}]`;
}

/**
 * Second chance when the fielded search finds nothing: any credited artist (a
 * service may list the composer first) with a recording of about the same
 * length, or with some of the title's words. Results are offered, not imported,
 * unless title and artist still agree.
 */
export function fallbackSearchQuery(title: string, artist: string, durationMs?: number): string | null {
  const artists = splitArtists(artist).slice(0, 4);
  if (!artists.length) return null;
  const who = artists.map((name) => `artist:${luceneQuote(name)}`).join(' OR ');
  if (durationMs) return `(${who}) AND ${durationWindow(durationMs)}`;
  const words = normalizeSearch(cleanTitle(title)).split(' ').filter((word) => word.length > 1).slice(0, 6);
  return words.length ? `(${who}) AND recording:(${words.join(' ')})` : null;
}

export function creditName(credits: MbArtistCredit[] | undefined): string {
  return (credits ?? []).map((credit) => `${credit.name ?? credit.artist?.name ?? ''}${credit.joinphrase ?? ''}`).join('').trim();
}

const VERSION_WORDS = /\b(live|demo|remix|mix|session|sessions|instrumental|acoustic|karaoke|edit|rehearsal|take|bbc|unplugged|cover|version|alternate|early)\b/i;

/** Ranks a release for "the album this recording belongs to": official studio albums first. */
export function releasePreference(release: MbReleaseRef): number {
  let score = 0;
  if (release.status === 'Official') score += 4;
  const group = release['release-group'];
  const primary = group?.['primary-type'] ?? undefined;
  if (primary === 'Album') score += 3;
  else if (primary === 'EP') score += 2;
  else if (primary === 'Single') score += 1;
  const secondary = group?.['secondary-types'] ?? [];
  if (!secondary.length) score += 3;
  if (secondary.some((type) => /live|compilation|dj-mix|mixtape|remix|demo/i.test(type))) score -= 4;
  return score;
}

/** MusicBrainz's "Various Artists" special-purpose artist. */
export const VARIOUS_ARTISTS_MBID = '89ad4ac3-39f7-470e-963a-56509c546377';

/**
 * A release whose other tracks do not belong to the recording's artist or album:
 * a compilation, DJ mix, or mixtape, or anything credited to Various Artists.
 */
export function isAnthology(group: MbReleaseGroup | undefined, releaseArtistMbid?: string): boolean {
  if (releaseArtistMbid === VARIOUS_ARTISTS_MBID) return true;
  return (group?.['secondary-types'] ?? []).some((type) => /compilation|dj-mix|mixtape/i.test(type));
}

/** The release whose release group should represent this recording, if any. */
export function preferredRelease(releases: MbReleaseRef[] | undefined): MbReleaseRef | undefined {
  return [...(releases ?? [])]
    .filter((release) => release.id)
    .sort((a, b) => releasePreference(b) - releasePreference(a) || String(a.date || '9999').localeCompare(String(b.date || '9999')))[0];
}

export interface TrackForMatching { title: string; artist: string; durationMs?: number }

export interface ScoredCandidate {
  recording: MbRecording;
  points: number;
  titleMatch: boolean;
  artistMatch: boolean;
  /** 'strong' ≤ 5 s apart, 'ok' ≤ 15 s, 'far' beyond, 'unknown' when either side lacks a duration. */
  duration: 'strong' | 'ok' | 'far' | 'unknown';
  versionMismatch: boolean;
}

export function durationCloseness(a?: number | null, b?: number | null): ScoredCandidate['duration'] {
  if (!a || !b) return 'unknown';
  const delta = Math.abs(a - b);
  if (delta <= 5_000) return 'strong';
  if (delta <= 15_000) return 'ok';
  return 'far';
}

export function scoreRecording(track: TrackForMatching, recording: MbRecording): ScoredCandidate {
  const titleMatch = sameTitle(track.title, recording.title ?? '');
  const credit = creditName(recording['artist-credit']);
  const firstCredit = recording['artist-credit']?.[0]?.name ?? recording['artist-credit']?.[0]?.artist?.name ?? '';
  const artistMatch = Boolean(track.artist) && (sameArtist(track.artist, credit) || sameArtist(track.artist, firstCredit));
  const duration = durationCloseness(track.durationMs, recording.length);
  const marker = VERSION_WORDS.exec(recording.disambiguation ?? '')?.[0]?.toLowerCase();
  const versionMismatch = Boolean(marker && !fold(track.title).includes(marker));
  const releases = recording.releases ?? [];
  const best = preferredRelease(releases);

  let points = 0;
  if (titleMatch) points += 40;
  if (artistMatch) points += 40;
  points += { strong: 15, ok: 8, unknown: 0, far: -20 }[duration];
  if (versionMismatch) points -= 25;
  if (recording.video) points -= 30;
  // Canonical recordings appear on many releases; one-off mixes on one.
  points += Math.min(10, Math.log2(releases.length + 1) * 2);
  if (best) points += Math.max(0, releasePreference(best)) / 2;
  return { recording, points, titleMatch, artistMatch, duration, versionMismatch };
}

/** Orders candidates best first; ties go to the earliest release. */
export function rankRecordings(track: TrackForMatching, recordings: MbRecording[]): ScoredCandidate[] {
  return recordings
    .filter((recording) => recording.id)
    .map((recording) => scoreRecording(track, recording))
    .sort((a, b) => b.points - a.points || String(a.recording['first-release-date'] || '9999').localeCompare(String(b.recording['first-release-date'] || '9999')));
}

/**
 * How sure a search match is. Strong means safe to import without asking:
 * same title and artist, not a different version, and the durations agree
 * within 5 s (or the source gave no duration to compare).
 */
export function classifyCandidate(candidate: ScoredCandidate | undefined): Confidence {
  if (!candidate) return 'none';
  const { titleMatch, artistMatch, duration, versionMismatch, recording } = candidate;
  if (titleMatch && artistMatch && !versionMismatch && !recording.video && (duration === 'strong' || duration === 'unknown')) return 'strong';
  return 'weak';
}

/** A MusicBrainz recording as an unimported search result (ids match /api/music/search). */
export function recordingToSearchResult(recording: MbRecording): SearchResult {
  const artistName = creditName(recording['artist-credit']) || 'Unknown artist';
  const release = preferredRelease(recording.releases);
  const albumName = release?.['release-group']?.title ?? release?.title ?? '';
  const entity: Song = {
    id: `mb-song-${recording.id}`,
    kind: 'song',
    name: recording.title ?? 'Unknown recording',
    slug: slugify(recording.title ?? recording.id),
    artistId: `remote-${slugify(artistName)}`,
    albumId: albumName ? `remote-${slugify(albumName)}` : undefined,
    durationMs: recording.length ? Number(recording.length) : undefined,
    musicbrainzId: recording.id,
  };
  return { entity, subtitle: [artistName, albumName, 'MusicBrainz'].filter(Boolean).join(' · '), source: 'musicbrainz' };
}

/**
 * Among recordings sharing an ISRC, the one that best fits what the source said.
 * Without a title to compare, the canonical recording wins: the one on the most
 * releases, then the one whose best release is an official studio album (a
 * recording that only ever appeared on one compilation loses), then the one
 * released first.
 */
export function pickIsrcRecording(track: Partial<TrackForMatching>, recordings: MbRecording[]): MbRecording | undefined {
  const usable = recordings.filter((recording) => recording.id && !recording.video);
  if (track.title) return rankRecordings({ title: track.title, artist: track.artist ?? '', durationMs: track.durationMs }, usable)[0]?.recording;
  const albumScore = (recording: MbRecording) => {
    const best = preferredRelease(recording.releases);
    return best ? releasePreference(best) : -99;
  };
  const firstReleased = (recording: MbRecording) => recording['first-release-date'] || '9999';
  return usable
    .map((recording, index) => ({ recording, index }))
    .sort((a, b) => (b.recording.releases?.length ?? 0) - (a.recording.releases?.length ?? 0)
      || albumScore(b.recording) - albumScore(a.recording)
      || firstReleased(a.recording).localeCompare(firstReleased(b.recording))
      || a.index - b.index)[0]?.recording;
}

/** Titles that name the same song, allowing one to extend the other ("IV. Presto" / "IV. Presto – Allegro assai"). */
export function titlesAgree(a: string, b: string): boolean {
  if (sameTitle(a, b)) return true;
  const left = fold(cleanTitle(a));
  const right = fold(cleanTitle(b));
  if (left.length < 4 || right.length < 4) return false;
  return left.startsWith(right) || right.startsWith(left);
}

/** Whether any credited name in the source's artist string is the catalog artist. */
export function artistsAgree(trackArtist: string, catalogArtist: string): boolean {
  return sameArtist(trackArtist, catalogArtist) || splitArtists(trackArtist).some((name) => sameArtist(name, catalogArtist));
}

/**
 * Whether a cached id → song row is plausible for what the source reported. An
 * id-only track (no title or artist) cannot disagree. A row is rejected only when
 * both the title and the artist disagree, so a classical track whose source lists
 * the composer while MusicBrainz credits the performers still reuses its row.
 */
export function trackPlausiblyIs(track: { title: string; artist: string }, song: { name: string }, artistName?: string): boolean {
  if (!track.title && !track.artist) return true;
  const titleOk = Boolean(track.title) && titlesAgree(track.title, song.name);
  const artistOk = Boolean(track.artist && artistName) && artistsAgree(track.artist, artistName!);
  return titleOk || artistOk;
}

/** Whether the source's title and artist name this song outright, so its `text:` key may point at it. */
export function trackNamesSong(track: { title: string; artist: string }, song: { name: string }, artistName?: string): boolean {
  return Boolean(track.title && track.artist && artistName) && sameTitle(track.title, song.name) && sameArtist(track.artist, artistName!);
}

/** MusicBrainz genres ordered by votes, dropping empty names. */
export function topGenres(genres: MbGenre[] | undefined, limit = 6): Array<{ id: string; name: string; count: number }> {
  return (genres ?? [])
    .filter((genre): genre is Required<Pick<MbGenre, 'id' | 'name'>> & MbGenre => Boolean(genre.id && genre.name))
    .map((genre) => ({ id: genre.id, name: genre.name, count: genre.count ?? 0 }))
    .sort((a, b) => b.count - a.count || a.name.localeCompare(b.name))
    .slice(0, limit);
}

/** Identifiers a track can be cached under, most trustworthy first. */
export interface KeyedTrack { title: string; artist: string; mbid?: string; isrc?: string; spotifyId?: string; appleMusicId?: string; youtubeId?: string }

export function mbidKey(mbid: string): string {
  return `mbid:${mbid.toLowerCase()}`;
}

export function isrcKey(isrc: string): string {
  return `isrc:${isrc.toUpperCase()}`;
}

/** The `text:` key, or undefined when the artist or title folds to nothing. */
export function textKey(track: { title: string; artist: string }): string | undefined {
  return fold(primaryArtist(track.artist)) && fold(cleanTitle(track.title)) ? `text:${matchKey(track.artist, track.title)}` : undefined;
}

/**
 * Every key a track could be found under, for reading the cache. Writing is
 * narrower: only keys the server verified are stored (see resolve.ts).
 */
export function resolutionKeys(track: KeyedTrack): string[] {
  const keys: string[] = [];
  if (track.mbid) keys.push(mbidKey(track.mbid));
  if (track.isrc) keys.push(isrcKey(track.isrc));
  if (track.spotifyId) keys.push(`url:https://open.spotify.com/track/${track.spotifyId}`);
  if (track.appleMusicId) keys.push(`url:https://music.apple.com/song/${track.appleMusicId}`);
  if (track.youtubeId) keys.push(`url:https://www.youtube.com/watch?v=${track.youtubeId}`);
  const text = textKey(track);
  if (text) keys.push(text);
  return keys;
}

/** Orders cached rows by key trust (mbid › isrc › url › text). */
export function keyRank(key: string): number {
  const prefix = key.slice(0, key.indexOf(':'));
  return ['mbid', 'isrc', 'url', 'text'].indexOf(prefix) + 1 || 9;
}
