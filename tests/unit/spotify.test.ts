import { describe, expect, it } from 'vitest';
import { mapLastfmRecentList, mergeRecentPlays } from '@/lib/music/scrobbles';
import {
  applyTokenRefresh,
  combineSpotifyPlays,
  authorizationCodeBody,
  callbackScheme,
  canPlay,
  isUnavailableStatus,
  isValidAuthCode,
  isValidAuthState,
  isValidCodeChallenge,
  isValidCodeVerifier,
  mapSpotifyCurrentlyPlaying,
  mapSpotifyDevices,
  mapSpotifyRecentlyPlayed,
  needsRefresh,
  parsePlaybackRequest,
  parseSpotifyProfile,
  parseSpotifyToken,
  playbackCall,
  playbackOutcome,
  refreshTokenBody,
  SPOTIFY_SCOPES,
  spotifyAuthUrl,
  spotifyBasicAuth,
} from '@/lib/music/spotify';

const NOW = 1792859270_000; // 2026-10-24T16:27:50Z
const MIN = 60_000;
const CHALLENGE = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
const STATE = 'af0ifjsldkj_state-1';
const TRACK_ID = '7H7RaiZoTNPwjNLygV4fXQ';

/** A Spotify track object, trimmed from the documented Web API shape. */
function spotifyTrack(extra: Record<string, unknown> = {}) {
  return {
    id: TRACK_ID,
    name: 'Weird Fishes/Arpeggi',
    duration_ms: 318186,
    artists: [{ name: 'Radiohead' }, { name: 'Guest' }],
    album: {
      name: 'In Rainbows',
      images: [
        { url: 'https://i.scdn.co/image/300', width: 300, height: 300 },
        { url: 'https://i.scdn.co/image/640', width: 640, height: 640 },
        { url: 'https://i.scdn.co/image/64', width: 64, height: 64 },
      ],
    },
    external_ids: { isrc: 'gbstk0700005' },
    external_urls: { spotify: `https://open.spotify.com/track/${TRACK_ID}` },
    ...extra,
  };
}

describe('Spotify sign-in', () => {
  it('builds the authorize URL with PKCE S256, the scopes and the redirect', () => {
    const url = new URL(spotifyAuthUrl({ clientId: 'client123', redirectUri: 'resonote://spotify-auth', codeChallenge: CHALLENGE, state: STATE }));
    expect(url.origin + url.pathname).toBe('https://accounts.spotify.com/authorize');
    expect(Object.fromEntries(url.searchParams)).toEqual({
      response_type: 'code',
      client_id: 'client123',
      scope: 'user-read-recently-played user-read-currently-playing user-read-playback-state user-modify-playback-state',
      redirect_uri: 'resonote://spotify-auth',
      code_challenge_method: 'S256',
      code_challenge: CHALLENGE,
      state: STATE,
    });
    expect(SPOTIFY_SCOPES.split(' ')).toHaveLength(4);
    expect(callbackScheme('resonote://spotify-auth')).toBe('resonote');
    expect(callbackScheme('Other.App://cb')).toBe('other.app');
  });

  it('validates the challenge, state, code and verifier', () => {
    expect(isValidCodeChallenge(CHALLENGE)).toBe(true);
    expect(isValidCodeChallenge('a'.repeat(42))).toBe(false);
    expect(isValidCodeChallenge('a'.repeat(129))).toBe(false);
    expect(isValidCodeChallenge(`${CHALLENGE.slice(1)}=`)).toBe(false);
    expect(isValidCodeChallenge(`${CHALLENGE.slice(1)}+`)).toBe(false);
    expect(isValidCodeChallenge(undefined)).toBe(false);

    expect(isValidAuthState(STATE)).toBe(true);
    expect(isValidAuthState('short')).toBe(false);
    expect(isValidAuthState('a'.repeat(129))).toBe(false);
    expect(isValidAuthState('has space in the state')).toBe(false);
    expect(isValidAuthState(null)).toBe(false);

    expect(isValidCodeVerifier('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk')).toBe(true);
    expect(isValidCodeVerifier('a.b~c-d_'.repeat(6))).toBe(true);
    expect(isValidCodeVerifier('short')).toBe(false);
    expect(isValidCodeVerifier('a'.repeat(129))).toBe(false);

    expect(isValidAuthCode('AQB4x_y-Z.1~')).toBe(true);
    expect(isValidAuthCode('')).toBe(false);
    expect(isValidAuthCode('a b')).toBe(false);
    expect(isValidAuthCode(42)).toBe(false);
  });

  it('builds the token requests with Basic auth', () => {
    expect(spotifyBasicAuth('id', 'secret')).toBe(`Basic ${Buffer.from('id:secret').toString('base64')}`);
    expect(Object.fromEntries(authorizationCodeBody('the-code', 'resonote://spotify-auth', 'verifier'))).toEqual({
      grant_type: 'authorization_code', code: 'the-code', redirect_uri: 'resonote://spotify-auth', code_verifier: 'verifier',
    });
    expect(Object.fromEntries(refreshTokenBody('refresh-1'))).toEqual({ grant_type: 'refresh_token', refresh_token: 'refresh-1' });
  });

  it('reads tokens, and tells invalid_grant from a failure', () => {
    expect(parseSpotifyToken({ access_token: 'at', token_type: 'Bearer', expires_in: 3600, refresh_token: 'rt', scope: SPOTIFY_SCOPES }))
      .toEqual({ kind: 'token', accessToken: 'at', expiresIn: 3600, refreshToken: 'rt', scope: SPOTIFY_SCOPES });
    expect(parseSpotifyToken({ access_token: 'at', expires_in: 3600 })).toEqual({ kind: 'token', accessToken: 'at', expiresIn: 3600, refreshToken: undefined, scope: undefined });
    expect(parseSpotifyToken({ error: 'invalid_grant', error_description: 'Invalid authorization code' })).toEqual({ kind: 'rejected' });
    expect(parseSpotifyToken({ error: 'invalid_client' })).toEqual({ kind: 'failed' });
    expect(parseSpotifyToken({ access_token: 'at' })).toEqual({ kind: 'failed' });
    expect(parseSpotifyToken(null)).toEqual({ kind: 'failed' });
  });

  it('reads the profile and Premium', () => {
    expect(parseSpotifyProfile({ id: 'wizzler', display_name: 'Wiz', product: 'premium', email: 'x' })).toEqual({ id: 'wizzler', displayName: 'Wiz', product: 'premium' });
    expect(parseSpotifyProfile({ id: 'free-person', display_name: null, product: 'free' })).toEqual({ id: 'free-person', displayName: undefined, product: 'free' });
    expect(parseSpotifyProfile({ error: { status: 403 } })).toBeNull();
    expect(canPlay('premium')).toBe(true);
    expect(canPlay('free')).toBe(false);
    expect(canPlay(null)).toBe(false);
  });
});

describe('Spotify token refresh', () => {
  it('refreshes when the access token is missing or expires within a minute', () => {
    expect(needsRefresh({ accessToken: null, accessExpiresAt: null }, NOW)).toBe(true);
    expect(needsRefresh({ accessToken: 'at', accessExpiresAt: null }, NOW)).toBe(true);
    expect(needsRefresh({ accessToken: 'at', accessExpiresAt: 'soon' }, NOW)).toBe(true);
    expect(needsRefresh({ accessToken: 'at', accessExpiresAt: new Date(NOW + 59_000).toISOString() }, NOW)).toBe(true);
    expect(needsRefresh({ accessToken: 'at', accessExpiresAt: new Date(NOW + 60_000).toISOString() }, NOW)).toBe(true);
    expect(needsRefresh({ accessToken: 'at', accessExpiresAt: new Date(NOW + 61_000).toISOString() }, NOW)).toBe(false);
  });

  it('stores a rotated refresh token, and keeps the old one when none is returned', () => {
    const stored = { accessToken: 'old-at', accessExpiresAt: new Date(NOW).toISOString(), refreshToken: 'rt-1' };
    expect(applyTokenRefresh(stored, { accessToken: 'at-2', expiresIn: 3600, refreshToken: 'rt-2' }, NOW))
      .toEqual({ accessToken: 'at-2', accessExpiresAt: new Date(NOW + 3_600_000).toISOString(), refreshToken: 'rt-2' });
    expect(applyTokenRefresh(stored, { accessToken: 'at-3', expiresIn: 3600 }, NOW).refreshToken).toBe('rt-1');
  });
});

describe('Spotify listening', () => {
  it('reads nothing from a 204, an episode, an ad, or an empty item', () => {
    expect(mapSpotifyCurrentlyPlaying(204, null, NOW)).toBeNull();
    expect(mapSpotifyCurrentlyPlaying(200, { currently_playing_type: 'episode', is_playing: true, item: { name: 'Podcast' } }, NOW)).toBeNull();
    expect(mapSpotifyCurrentlyPlaying(200, { currently_playing_type: 'ad', is_playing: true, item: null }, NOW)).toBeNull();
    expect(mapSpotifyCurrentlyPlaying(200, { currently_playing_type: 'track', is_playing: true, item: null }, NOW)).toBeNull();
    expect(mapSpotifyCurrentlyPlaying(200, null, NOW)).toBeNull();
  });

  it('maps a playing track with ISRC, the largest artwork and joined artists', () => {
    expect(mapSpotifyCurrentlyPlaying(200, { currently_playing_type: 'track', is_playing: true, progress_ms: 1000, item: spotifyTrack() }, NOW)).toEqual({
      title: 'Weird Fishes/Arpeggi',
      artist: 'Radiohead, Guest',
      album: 'In Rainbows',
      durationMs: 318186,
      artworkURL: 'https://i.scdn.co/image/640',
      isrc: 'GBSTK0700005',
      spotifyId: TRACK_ID,
      url: `https://open.spotify.com/track/${TRACK_ID}`,
      source: 'spotify',
      isPlaying: true,
      observedAt: new Date(NOW).toISOString(),
    });
  });

  it('observes a paused track at the response timestamp, and drops it once that is stale or missing', () => {
    const paused = (timestamp?: number) => mapSpotifyCurrentlyPlaying(200, { timestamp, currently_playing_type: 'track', is_playing: false, item: spotifyTrack() }, NOW);
    expect(paused(NOW - 3 * MIN)).toMatchObject({ isPlaying: false, observedAt: new Date(NOW - 3 * MIN).toISOString(), source: 'spotify' });
    expect(paused(NOW - 11 * MIN)).toBeNull();
    expect(paused(NOW - 5 * 3_600_000)).toBeNull();
    expect(paused(undefined)).toBeNull();
    // A playing row is observed at the sample time whatever the timestamp says.
    expect(mapSpotifyCurrentlyPlaying(200, { timestamp: NOW - 5 * 3_600_000, currently_playing_type: 'track', is_playing: true, item: spotifyTrack() }, NOW))
      .toMatchObject({ isPlaying: true, observedAt: new Date(NOW).toISOString() });
  });

  it('drops a paused live row that recently-played already has', () => {
    const live = mapSpotifyCurrentlyPlaying(200, { timestamp: NOW - 2 * MIN, currently_playing_type: 'track', is_playing: false, item: spotifyTrack() }, NOW)!;
    const sameById = mapSpotifyRecentlyPlayed({ items: [{ track: spotifyTrack({ name: 'Renamed' }), played_at: new Date(NOW - 3 * MIN).toISOString() }] });
    expect(combineSpotifyPlays(live, sameById)).toEqual(sameById);
    const sameByText = mapSpotifyRecentlyPlayed({ items: [{ track: spotifyTrack({ id: null, name: 'Weird Fishes / Arpeggi' }), played_at: new Date(NOW - 1 * MIN).toISOString() }] });
    expect(combineSpotifyPlays(live, sameByText)).toEqual(sameByText);
    // An older play of the same song, or a different song, leaves the live row.
    const older = mapSpotifyRecentlyPlayed({ items: [{ track: spotifyTrack(), played_at: new Date(NOW - 40 * MIN).toISOString() }] });
    expect(combineSpotifyPlays(live, older)).toEqual([live, ...older]);
    const other = mapSpotifyRecentlyPlayed({ items: [{ track: spotifyTrack({ id: '0'.repeat(22), name: 'Nude' }), played_at: new Date(NOW - 3 * MIN).toISOString() }] });
    expect(combineSpotifyPlays(live, other)).toEqual([live, ...other]);
    // A playing row always stays.
    const playing = { ...live, isPlaying: true, observedAt: new Date(NOW).toISOString() };
    expect(combineSpotifyPlays(playing, sameById)).toEqual([playing, ...sameById]);
    expect(combineSpotifyPlays(null, other)).toEqual(other);
  });

  it('maps recently-played at each played_at, newest first, skipping undated and unnamed rows', () => {
    const list = mapSpotifyRecentlyPlayed({
      items: [
        { track: spotifyTrack({ name: 'Nude', id: '0'.repeat(22) }), played_at: new Date(NOW - 20 * MIN).toISOString() },
        { track: spotifyTrack(), played_at: new Date(NOW - 5 * MIN).toISOString() },
        { track: spotifyTrack({ name: 'Undated' }) },
        { track: spotifyTrack({ artists: [] }), played_at: new Date(NOW).toISOString() },
        { track: spotifyTrack({ id: null, name: 'Local file', external_urls: {}, album: { name: 'Mine', images: [] }, external_ids: {} }), played_at: new Date(NOW - 30 * MIN).toISOString() },
      ],
    });
    expect(list.map((track) => track.title)).toEqual(['Weird Fishes/Arpeggi', 'Nude', 'Local file']);
    expect(list[0]).toMatchObject({ isrc: 'GBSTK0700005', artworkURL: 'https://i.scdn.co/image/640', isPlaying: false, observedAt: new Date(NOW - 5 * MIN).toISOString() });
    expect(list[2]).toMatchObject({ spotifyId: undefined, url: undefined, artworkURL: undefined, isrc: undefined });
    expect(mapSpotifyRecentlyPlayed(null)).toEqual([]);
    expect(mapSpotifyRecentlyPlayed({ error: { status: 401 } })).toEqual([]);
  });

  it('merges a Spotify play with its Last.fm scrobble into one row', () => {
    const spotify = mapSpotifyRecentlyPlayed({ items: [{ track: spotifyTrack({ artists: [{ name: 'Radiohead' }] }), played_at: new Date(NOW - 2 * MIN).toISOString() }] });
    const lastfm = mapLastfmRecentList({
      recenttracks: { track: [{ name: 'Weird Fishes / Arpeggi', artist: { '#text': 'Radiohead' }, album: { '#text': 'In Rainbows' }, date: { uts: String((NOW - 7 * MIN) / 1000) }, mbid: '0b6ddb52-b0a1-4b3a-9c1f-6f3b7d5e2a10' }] },
    }, NOW);
    const merged = mergeRecentPlays([lastfm, null, spotify]);
    expect(merged).toHaveLength(1);
    expect(merged[0]).toMatchObject({
      source: 'spotify', spotifyId: TRACK_ID, isrc: 'GBSTK0700005', mbid: '0b6ddb52-b0a1-4b3a-9c1f-6f3b7d5e2a10', observedAt: new Date(NOW - 2 * MIN).toISOString(),
    });
  });

  it('keeps repeat Spotify plays of one song as separate rows', () => {
    const list = mapSpotifyRecentlyPlayed({
      items: [
        { track: spotifyTrack(), played_at: new Date(NOW - 2 * MIN).toISOString() },
        { track: spotifyTrack(), played_at: new Date(NOW - 8 * MIN).toISOString() },
      ],
    });
    expect(mergeRecentPlays([list])).toHaveLength(2);
  });

  it('counts throttling and outages as unavailable', () => {
    expect([429, 500, 503].every(isUnavailableStatus)).toBe(true);
    expect([200, 204, 401, 403].some(isUnavailableStatus)).toBe(false);
  });
});

describe('Spotify playback', () => {
  it('validates playback requests', () => {
    expect(parsePlaybackRequest({ action: 'play', spotifyId: TRACK_ID, deviceId: 'abc123' })).toEqual({ action: 'play', spotifyId: TRACK_ID, deviceId: 'abc123' });
    expect(parsePlaybackRequest({ action: 'play' })).toEqual({ action: 'play' });
    expect(parsePlaybackRequest({ action: 'pause', spotifyId: TRACK_ID })).toEqual({ action: 'pause' });
    expect(parsePlaybackRequest({ action: 'next', deviceId: null })).toEqual({ action: 'next' });
    expect(parsePlaybackRequest({ action: 'stop' })).toBeNull();
    expect(parsePlaybackRequest({ action: 'play', spotifyId: 'short' })).toBeNull();
    expect(parsePlaybackRequest({ action: 'play', deviceId: 'a/b' })).toBeNull();
    expect(parsePlaybackRequest(null)).toBeNull();
  });

  it('maps actions to Web API calls', () => {
    expect(playbackCall({ action: 'play', spotifyId: TRACK_ID, deviceId: 'dev 1' })).toEqual({
      method: 'PUT', url: 'https://api.spotify.com/v1/me/player/play?device_id=dev%201', body: JSON.stringify({ uris: [`spotify:track:${TRACK_ID}`] }),
    });
    expect(playbackCall({ action: 'play' })).toEqual({ method: 'PUT', url: 'https://api.spotify.com/v1/me/player/play' });
    expect(playbackCall({ action: 'pause' })).toEqual({ method: 'PUT', url: 'https://api.spotify.com/v1/me/player/pause' });
    expect(playbackCall({ action: 'next', deviceId: 'd' })).toEqual({ method: 'POST', url: 'https://api.spotify.com/v1/me/player/next?device_id=d' });
    expect(playbackCall({ action: 'previous' })).toEqual({ method: 'POST', url: 'https://api.spotify.com/v1/me/player/previous' });
  });

  it('reads player answers', () => {
    expect(playbackOutcome(204)).toBe('ok');
    expect(playbackOutcome(200)).toBe('ok');
    expect(playbackOutcome(404)).toBe('no-device');
    expect(playbackOutcome(403)).toBe('premium-required');
    expect(playbackOutcome(429)).toBe('failed');
    expect(playbackOutcome(502)).toBe('failed');
  });

  it('maps devices, leaving out ones without an id', () => {
    expect(mapSpotifyDevices({
      devices: [
        { id: 'abc', is_active: true, name: "Nick's iPhone", type: 'Smartphone', volume_percent: 70 },
        { id: null, is_active: false, name: 'Restricted', type: 'Speaker', volume_percent: 10 },
        { id: 'def', is_active: false, name: 'Kitchen', type: 'Speaker', volume_percent: null },
      ],
    })).toEqual([
      { id: 'abc', name: "Nick's iPhone", type: 'Smartphone', isActive: true, volumePercent: 70 },
      { id: 'def', name: 'Kitchen', type: 'Speaker', isActive: false, volumePercent: null },
    ]);
    expect(mapSpotifyDevices(null)).toEqual([]);
  });
});
