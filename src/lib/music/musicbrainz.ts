import 'server-only';
import { getCloudflareContext } from '@opennextjs/cloudflare';
import type { Album, Artist, SearchResult, Song } from '@/lib/data/types';
import { slugify } from '@/lib/utils';

const BASE = 'https://musicbrainz.org/ws/2';
let queue = Promise.resolve();
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

async function throttledFetch(url: string) {
  const task = queue.then(async () => {
    const contact = await contactEmail();
    // MusicBrainz flakes occasionally (502/503/520). Stay in the queue and retry
    // with backoff so one rough response never fails an import or a search.
    for (let attempt = 0; attempt < 4; attempt += 1) {
      const wait = Math.max(0, 1050 - (Date.now() - lastRequestAt));
      if (wait) await new Promise((resolve) => setTimeout(resolve, wait));
      lastRequestAt = Date.now();
      let response: Response;
      try {
        response = await fetch(url, { headers: { Accept: 'application/json', 'User-Agent': `Resonote/0.1 (${contact})` }, next: { revalidate: 60 * 60 * 24 } });
      } catch {
        if (attempt === 3) throw new Error('MusicBrainz is unreachable right now.');
        await new Promise((resolve) => setTimeout(resolve, 2000 * (attempt + 1)));
        continue;
      }
      if (TRANSIENT.has(response.status) && attempt < 3) {
        await new Promise((resolve) => setTimeout(resolve, 2000 * (attempt + 1)));
        continue;
      }
      return response;
    }
    throw new Error('MusicBrainz kept failing after retries.');
  });
  queue = task.then(() => undefined, () => undefined);
  return task;
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
interface MbReleaseGroupRef { id?: string; title?: string; 'primary-type'?: string }
interface MbTrack { id?: string; title?: string; position?: number; length?: number; recording?: { id?: string; title?: string; length?: number } }
interface MbMedia { 'track-count'?: number; tracks?: MbTrack[] }
interface MbRelease { id?: string; title?: string; status?: string; date?: string; media?: MbMedia[]; 'release-group'?: MbReleaseGroupRef }

export interface ImportBundle {
  artists: Artist[];
  albums: Album[];
  songs: Song[];
  focusKind: 'artist' | 'album' | 'song';
  focusId: string;
}

async function fetchJsonOrThrow(url: string): Promise<Record<string, unknown>> {
  const response = await throttledFetch(url);
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

  bundle(focusKind: ImportBundle['focusKind'], focusId: string): ImportBundle {
    return { artists: [...this.artists.values()], albums: [...this.albums.values()], songs: [...this.songs.values()], focusKind, focusId };
  }
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

async function resolveReleaseGroupInto(builder: ImportBuilder, rgMbid: string): Promise<Album> {
  const group = await fetchJsonOrThrow(`${BASE}/release-group/${encodeURIComponent(rgMbid)}?inc=artist-credits&fmt=json`);
  const credit = creditArtist((group['artist-credit'] as MbCreditEntry[] | undefined)?.[0]);
  if (!credit) throw new Error('That release group has no resolvable artist credit.');
  const artist = builder.artist({ ...credit, country: undefined });

  const listing = await fetchJsonOrThrow(`${BASE}/release?release-group=${encodeURIComponent(rgMbid)}&status=official&fmt=json&limit=25`);
  const candidates = rankReleases((listing.releases as MbRelease[] | undefined) ?? []).filter((release) => release.id).slice(0, 3);
  if (!candidates.length) throw new Error('No official release exists for this album yet.');

  // Browse listings omit media/tracklists, so probe candidates until one yields tracks.
  let album: Album | undefined;
  for (const candidate of candidates) {
    const detail = await fetchJsonOrThrow(`${BASE}/release/${encodeURIComponent(candidate.id!)}?inc=recordings+artist-credits+media&fmt=json`);
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
      builder.song({
        recordingId: recording.id!,
        title: track.title ?? recording.title ?? 'Unknown track',
        artistId: artist.id,
        albumId: album.id,
        trackNumber: track.position,
        durationMs: track.length ?? recording.length ?? undefined,
      });
    }
    break;
  }
  if (!album) throw new Error('No release of this album carries a linked tracklist on MusicBrainz.');
  return album;
}

export async function resolveImport(kind: 'artist' | 'album' | 'song', mbid: string): Promise<ImportBundle> {
  if (kind === 'album') {
    const builder = new ImportBuilder();
    const album = await resolveReleaseGroupInto(builder, mbid);
    return builder.bundle('album', album.id);
  }

  if (kind === 'song') {
    const builder = new ImportBuilder();
    const recording = await fetchJsonOrThrow(`${BASE}/recording/${encodeURIComponent(mbid)}?inc=artist-credits+releases&fmt=json`);
    const credit = creditArtist((recording['artist-credit'] as MbCreditEntry[] | undefined)?.[0]);
    if (!credit) throw new Error('That recording has no resolvable artist credit.');
    const artist = builder.artist({ ...credit, country: undefined });

    const releases = (recording.releases as MbRelease[] | undefined) ?? [];
    const candidate = releases.find((release) => release.id);
    let releaseGroup: MbReleaseGroupRef | undefined;
    if (candidate?.id) {
      const releaseDetail = await fetchJsonOrThrow(`${BASE}/release/${encodeURIComponent(candidate.id)}?inc=release-groups&fmt=json`);
      releaseGroup = releaseDetail['release-group'] as MbReleaseGroupRef | undefined;
    }

    let albumId: string | undefined;
    if (releaseGroup?.id) {
      try {
        const album = await resolveReleaseGroupInto(builder, releaseGroup.id);
        albumId = album.id;
      } catch {
        albumId = undefined;
      }
    }

    const focused = builder.song({
      recordingId: mbid,
      title: String(recording.title ?? 'Unknown recording'),
      artistId: artist.id,
      albumId,
      durationMs: recording.length ? Number(recording.length) : undefined,
    });
    return builder.bundle('song', focused.id);
  }

  const builder = new ImportBuilder();
  const payload = await fetchJsonOrThrow(`${BASE}/artist/${encodeURIComponent(mbid)}?inc=aliases&fmt=json`);
  if (!payload.id || !payload.name) throw new Error('MusicBrainz has no artist with that identifier.');
  const artist = builder.artist({
    id: String(payload.id),
    name: String(payload.name),
    sortName: payload['sort-name'] ? String(payload['sort-name']) : undefined,
    country: payload.country ? String(payload.country) : undefined,
  });
  return builder.bundle('artist', artist.id);
}
