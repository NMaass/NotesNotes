import { describe, expect, it } from 'vitest';
import {
  isValidLastfmUser,
  isValidListenBrainzUser,
  mapLastfmRecentTracks,
  mapListenBrainzPlayingNow,
  mapListenBrainzRecent,
  pickNowPlaying,
  sanitizeTrack,
  type NowPlayingTrack,
} from '@/lib/music/scrobbles';
import { lastfmNowPlaying, listenBrainzListen, listenBrainzNothingPlaying, listenBrainzPlayingNow } from './fixtures/scrobbles';

const NOW = 1792859270_000; // 2026-10-24T16:27:50Z

describe('Last.fm recent tracks', () => {
  it('maps the now-playing track with the largest real image', () => {
    const track = mapLastfmRecentTracks(lastfmNowPlaying, NOW)!;
    expect(track).toMatchObject({ title: 'Lithium', artist: 'Nirvana', album: 'Nevermind', source: 'lastfm', isPlaying: true });
    expect(track.artworkURL).toContain('300x300');
    expect(track.mbid).toBeUndefined();
    expect(track.observedAt).toBe(new Date(NOW).toISOString());
  });

  it('falls back to a scrobble from the last ten minutes, skipping the placeholder star', () => {
    const payload = { recenttracks: { track: [lastfmNowPlaying.recenttracks.track[1]] } };
    const track = mapLastfmRecentTracks(payload, NOW)!;
    expect(track).toMatchObject({ title: 'When You Sleep', isPlaying: false, mbid: '6c5ab2a4-4ab0-4f43-8d41-2b4a77c1e7b4' });
    expect(track.artworkURL).toBeUndefined();
    expect(track.observedAt).toBe(new Date(1792859000_000).toISOString());
  });

  it('accepts a single track object and ignores stale scrobbles', () => {
    const single = { recenttracks: { track: lastfmNowPlaying.recenttracks.track[1] } };
    expect(mapLastfmRecentTracks(single, NOW)?.title).toBe('When You Sleep');
    expect(mapLastfmRecentTracks(single, NOW + 3_600_000)).toBeNull();
    expect(mapLastfmRecentTracks({ error: 6, message: 'User not found' }, NOW)).toBeNull();
  });
});

describe('ListenBrainz', () => {
  it('maps playing-now with ISRC, duration, and the Spotify id from additional_info', () => {
    const track = mapListenBrainzPlayingNow(listenBrainzPlayingNow, NOW)!;
    expect(track).toMatchObject({
      title: 'Nuclear Fusion',
      artist: 'HENGE',
      album: 'Journey to Voltus B LP',
      durationMs: 218707,
      isrc: 'GBAYE0601498',
      spotifyId: '4iV5W9uYEdYUVa79Axb7Rh',
      url: 'https://open.spotify.com/track/4iV5W9uYEdYUVa79Axb7Rh',
      source: 'listenbrainz',
      isPlaying: true,
    });
  });

  it('returns null when nothing is playing', () => {
    expect(mapListenBrainzPlayingNow(listenBrainzNothingPlaying, NOW)).toBeNull();
  });

  it('uses the latest listen within ten minutes, with mbid_mapping ids and cover art', () => {
    const recent = { payload: { listens: [{ ...listenBrainzListen, listened_at: NOW / 1000 - 120 }] } };
    const track = mapListenBrainzRecent(recent, NOW)!;
    expect(track).toMatchObject({
      title: 'Some Resolve',
      artist: 'Röyksopp',
      mbid: '30d08f4c-d825-4ae1-b79c-44242cddd7c0',
      durationMs: 402390,
      spotifyId: '7H7RaiZoTNPwjNLygV4fXQ',
      isPlaying: false,
      artworkURL: 'https://coverartarchive.org/release/f1418001-7f1e-46af-bfdb-95faeded8841/32916450708-500.jpg',
    });
    expect(track.observedAt).toBe(new Date(NOW - 120_000).toISOString());
  });

  it('ignores a latest listen older than ten minutes', () => {
    expect(mapListenBrainzRecent({ payload: { listens: [listenBrainzListen] } }, NOW)).toBeNull();
  });
});

describe('pickNowPlaying', () => {
  const base: NowPlayingTrack = { title: 'A', artist: 'B', source: 'lastfm', isPlaying: false, observedAt: '2026-10-24T16:00:00.000Z' };
  it('prefers an active track over a fresher finished one', () => {
    const playing = { ...base, title: 'playing', isPlaying: true, observedAt: '2026-10-24T15:00:00.000Z' };
    const fresher = { ...base, title: 'fresher', observedAt: '2026-10-24T16:20:00.000Z' };
    expect(pickNowPlaying([fresher, null, playing])?.title).toBe('playing');
  });
  it('breaks ties by freshness', () => {
    const older = { ...base, title: 'older' };
    const newer = { ...base, title: 'newer', source: 'listenbrainz' as const, observedAt: '2026-10-24T16:05:00.000Z' };
    expect(pickNowPlaying([older, newer])?.title).toBe('newer');
    expect(pickNowPlaying([null, undefined])).toBeNull();
  });
});

describe('usernames and client tracks', () => {
  it('validates usernames', () => {
    expect(isValidLastfmUser('rj')).toBe(true);
    expect(isValidLastfmUser('9lives')).toBe(false);
    expect(isValidLastfmUser('a'.repeat(65))).toBe(false);
    expect(isValidListenBrainzUser('mr_monkey')).toBe(true);
    expect(isValidListenBrainzUser('Björk Fan')).toBe(true);
    expect(isValidListenBrainzUser('../etc')).toBe(false);
    expect(isValidListenBrainzUser('x'.repeat(65))).toBe(false);
    // Real MusicBrainz names include email addresses and punctuation.
    expect(isValidListenBrainzUser('drdonatistefano@gmail.com')).toBe(true);
    expect(isValidListenBrainzUser("o'brien+music!")).toBe(true);
    expect(isValidListenBrainzUser('..')).toBe(false);
    expect(isValidListenBrainzUser('tab\there')).toBe(false);
    expect(isValidListenBrainzUser(' padded')).toBe(false);
  });

  it('keeps valid fields and drops malformed optional ones', () => {
    const track = sanitizeTrack({
      title: ' Lithium ', artist: 'Nirvana', durationMs: '257000', isrc: 'us-gf1-91-00345', mbid: 'not-a-uuid',
      spotifyId: 'short', youtubeId: 'pkcJEvMcnEg', source: 'apple-music', isPlaying: true, observedAt: '2026-10-24T16:00:00Z',
      artworkURL: 'javascript:alert(1)',
    })!;
    expect(track).toMatchObject({ title: 'Lithium', artist: 'Nirvana', durationMs: 257000, isrc: 'USGF19100345', youtubeId: 'pkcJEvMcnEg', source: 'apple-music', isPlaying: true });
    expect(track.mbid).toBeUndefined();
    expect(track.spotifyId).toBeUndefined();
    expect(track.artworkURL).toBeUndefined();
  });

  it('requires a title and artist unless an identifier is present', () => {
    expect(sanitizeTrack({ title: 'Lithium', source: 'manual' })).toBeNull();
    expect(sanitizeTrack({ isrc: 'GBAYE0601498' })).toMatchObject({ title: '', artist: '', isrc: 'GBAYE0601498', source: 'manual', isPlaying: false });
    expect(sanitizeTrack('nope')).toBeNull();
  });
});
