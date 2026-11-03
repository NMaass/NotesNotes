// Spotify sign-in (Authorization Code + PKCE), listening history and Spotify Connect
// playback (docs/IOS_API.md, "Linked accounts: Spotify"). Pure, so it is unit-tested
// directly; fetching and storage live in src/lib/server/spotify.ts.
import { normalizeIsrc, RECENT_WINDOW_MS, type NowPlayingTrack } from '@/lib/music/scrobbles';
import { matchKey } from '@/lib/music/text';

export const SPOTIFY_ACCOUNTS = 'https://accounts.spotify.com';
export const SPOTIFY_TOKEN_URL = `${SPOTIFY_ACCOUNTS}/api/token`;
export const SPOTIFY_API = 'https://api.spotify.com/v1';
/** Where Spotify sends the person back after they approve Resonote (SpotifyAuth.swift). */
export const SPOTIFY_DEFAULT_REDIRECT_URI = 'resonote://spotify-auth';
export const SPOTIFY_SCOPES = 'user-read-recently-played user-read-currently-playing user-read-playback-state user-modify-playback-state';
/** An access token this close to expiry is refreshed before use. */
export const SPOTIFY_REFRESH_MARGIN_MS = 60_000;

const SPOTIFY_ID = /^[A-Za-z0-9]{22}$/;

function text(value: unknown, max = 500): string | undefined {
  return typeof value === 'string' && value.trim() ? value.trim().slice(0, max) : undefined;
}

function positiveInt(value: unknown): number | undefined {
  const parsed = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? Math.round(parsed) : undefined;
}

// ---- Sign-in ----

/** An S256 PKCE challenge: base64url without padding, 43–128 characters. */
export function isValidCodeChallenge(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{43,128}$/.test(value);
}

/** The app's anti-forgery state: 16–128 letters, digits, `-` and `_`. */
export function isValidAuthState(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{16,128}$/.test(value);
}

/** A PKCE code verifier (RFC 7636): 43–128 unreserved characters. */
export function isValidCodeVerifier(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z0-9._~-]{43,128}$/.test(value);
}

/** An authorization code from the callback's `?code=`: opaque, URL-safe, bounded. */
export function isValidAuthCode(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z0-9._~-]{1,1024}$/.test(value);
}

/** The scheme ASWebAuthenticationSession waits for (`resonote` for the default redirect). */
export function callbackScheme(redirectUri: string): string {
  const match = /^([A-Za-z][A-Za-z0-9+.-]*):/.exec(redirectUri);
  return match ? match[1].toLowerCase() : 'resonote';
}

/** The page where the person approves Resonote; Spotify then opens the redirect with `?code=&state=`. */
export function spotifyAuthUrl(options: { clientId: string; redirectUri: string; codeChallenge: string; state: string }): string {
  const query = new URLSearchParams({
    response_type: 'code',
    client_id: options.clientId,
    scope: SPOTIFY_SCOPES,
    redirect_uri: options.redirectUri,
    code_challenge_method: 'S256',
    code_challenge: options.codeChallenge,
    state: options.state,
  });
  return `${SPOTIFY_ACCOUNTS}/authorize?${query.toString()}`;
}

/** `Authorization: Basic base64(client_id:client_secret)` for the token endpoint. */
export function spotifyBasicAuth(clientId: string, clientSecret: string): string {
  return `Basic ${btoa(`${clientId}:${clientSecret}`)}`;
}

export function authorizationCodeBody(code: string, redirectUri: string, codeVerifier: string): URLSearchParams {
  return new URLSearchParams({ grant_type: 'authorization_code', code, redirect_uri: redirectUri, code_verifier: codeVerifier });
}

export function refreshTokenBody(refreshToken: string): URLSearchParams {
  return new URLSearchParams({ grant_type: 'refresh_token', refresh_token: refreshToken });
}

export type SpotifyTokenResult =
  | { kind: 'token'; accessToken: string; expiresIn: number; refreshToken?: string; scope?: string }
  | { kind: 'rejected' }
  | { kind: 'failed' };

/**
 * Reads a token endpoint answer: `{ access_token, expires_in, refresh_token?, scope }`,
 * or `{ error, error_description }`. Only `invalid_grant` (a used, expired or revoked
 * code or refresh token) is the person's to retry; anything else is a failure.
 */
export function parseSpotifyToken(payload: unknown): SpotifyTokenResult {
  const body = payload as Record<string, unknown> | null;
  if (!body || typeof body !== 'object') return { kind: 'failed' };
  if (body.error !== undefined) return body.error === 'invalid_grant' ? { kind: 'rejected' } : { kind: 'failed' };
  const accessToken = text(body.access_token, 4096);
  const expiresIn = positiveInt(body.expires_in);
  if (!accessToken || !expiresIn) return { kind: 'failed' };
  return { kind: 'token', accessToken, expiresIn, refreshToken: text(body.refresh_token, 4096), scope: text(body.scope, 1000) };
}

export interface SpotifyTokens { accessToken: string | null; accessExpiresAt: string | null; refreshToken: string }

/** Refresh when there is no access token, or it expires within SPOTIFY_REFRESH_MARGIN_MS. */
export function needsRefresh(tokens: Pick<SpotifyTokens, 'accessToken' | 'accessExpiresAt'>, now = Date.now()): boolean {
  if (!tokens.accessToken || !tokens.accessExpiresAt) return true;
  const expires = Date.parse(tokens.accessExpiresAt);
  return Number.isNaN(expires) || expires - now <= SPOTIFY_REFRESH_MARGIN_MS;
}

/** The stored tokens after a refresh: Spotify may rotate the refresh token, else the old one stays. */
export function applyTokenRefresh(stored: SpotifyTokens, token: { accessToken: string; expiresIn: number; refreshToken?: string }, now = Date.now()): SpotifyTokens {
  return {
    accessToken: token.accessToken,
    accessExpiresAt: new Date(now + token.expiresIn * 1000).toISOString(),
    refreshToken: token.refreshToken ?? stored.refreshToken,
  };
}

export interface SpotifyProfile { id: string; displayName?: string; product?: string }

/** `GET /v1/me` → id, display_name, product. */
export function parseSpotifyProfile(payload: unknown): SpotifyProfile | null {
  const body = payload as Record<string, unknown> | null;
  const id = text(body?.id, 200);
  if (!id) return null;
  return { id, displayName: text(body?.display_name, 200), product: text(body?.product, 50) };
}

/** Playback through the Web API needs Premium. */
export function canPlay(product: string | null | undefined): boolean {
  return product === 'premium';
}

// ---- Listening ----

function largestImage(images: unknown): string | undefined {
  const list = Array.isArray(images) ? images as Array<{ url?: unknown; width?: unknown }> : [];
  return list
    .filter((image) => text(image.url, 2048)?.startsWith('https://'))
    .sort((a, b) => (positiveInt(b.width) ?? 0) - (positiveInt(a.width) ?? 0))[0]?.url as string | undefined;
}

/** One Spotify track object as a NowPlayingTrack. Local files (no id) keep their text. */
export function mapSpotifyTrack(item: unknown, options: { isPlaying: boolean; observedAt: string }): NowPlayingTrack | null {
  const track = item as Record<string, unknown> | null;
  if (!track || typeof track !== 'object') return null;
  const title = text(track.name);
  const artists = (Array.isArray(track.artists) ? track.artists as Array<{ name?: unknown }> : [])
    .map((artist) => text(artist?.name))
    .filter((name): name is string => Boolean(name));
  if (!title || !artists.length) return null;
  const album = track.album as { name?: unknown; images?: unknown } | undefined;
  const spotifyId = typeof track.id === 'string' && SPOTIFY_ID.test(track.id) ? track.id : undefined;
  const url = text((track.external_urls as { spotify?: unknown } | undefined)?.spotify, 2048);
  return {
    title,
    artist: artists.join(', ').slice(0, 500),
    album: text(album?.name),
    durationMs: positiveInt(track.duration_ms),
    artworkURL: largestImage(album?.images),
    isrc: normalizeIsrc((track.external_ids as { isrc?: unknown } | undefined)?.isrc),
    spotifyId,
    url: url?.startsWith('https://') ? url : spotifyId ? `https://open.spotify.com/track/${spotifyId}` : undefined,
    source: 'spotify',
    isPlaying: options.isPlaying,
    observedAt: options.observedAt,
  };
}

/**
 * `GET /v1/me/player/currently-playing`: 204 (or an empty body) is nothing playing;
 * only a track item counts (episodes and ads do not). A playing item is observed at
 * the sample time. A paused one is observed at the response's `timestamp` (ms, when
 * playback last changed), and is left out when that is older than RECENT_WINDOW_MS
 * or missing: Spotify keeps reporting a track paused hours ago.
 */
export function mapSpotifyCurrentlyPlaying(status: number, payload: unknown, now = Date.now()): NowPlayingTrack | null {
  if (status === 204) return null;
  const body = payload as { currently_playing_type?: unknown; is_playing?: unknown; item?: unknown; timestamp?: unknown } | null;
  if (!body || body.currently_playing_type !== 'track' || !body.item) return null;
  if (body.is_playing === true) return mapSpotifyTrack(body.item, { isPlaying: true, observedAt: new Date(now).toISOString() });
  const changedAt = positiveInt(body.timestamp);
  if (!changedAt || now - changedAt > RECENT_WINDOW_MS) return null;
  return mapSpotifyTrack(body.item, { isPlaying: false, observedAt: new Date(Math.min(changedAt, now)).toISOString() });
}

function sameSpotifySong(a: NowPlayingTrack, b: NowPlayingTrack): boolean {
  if (a.spotifyId && a.spotifyId === b.spotifyId) return true;
  const key = matchKey(a.artist, a.title);
  return !key.startsWith('|') && !key.endsWith('|') && key === matchKey(b.artist, b.title);
}

/**
 * Spotify's rows for one request: the live row (if any), then recently-played. A
 * paused live row that is a recently-played row of the same song within
 * RECENT_WINDOW_MS (same spotifyId or TrackText key) is that play, so it is dropped.
 */
export function combineSpotifyPlays(live: NowPlayingTrack | null, history: NowPlayingTrack[]): NowPlayingTrack[] {
  const duplicate = live && !live.isPlaying && history.some((row) =>
    sameSpotifySong(live, row) && Math.abs(Date.parse(live.observedAt) - Date.parse(row.observedAt)) < RECENT_WINDOW_MS);
  return [...(live && !duplicate ? [live] : []), ...history];
}

/** `GET /v1/me/player/recently-played` → every play, newest first, at its `played_at`. */
export function mapSpotifyRecentlyPlayed(payload: unknown): NowPlayingTrack[] {
  const items = (payload as { items?: unknown } | null)?.items;
  const list = Array.isArray(items) ? items as Array<{ track?: unknown; played_at?: unknown }> : [];
  const mapped: NowPlayingTrack[] = [];
  for (const item of list) {
    const playedAt = typeof item?.played_at === 'string' ? Date.parse(item.played_at) : Number.NaN;
    if (Number.isNaN(playedAt)) continue;
    const track = mapSpotifyTrack(item.track, { isPlaying: false, observedAt: new Date(playedAt).toISOString() });
    if (track) mapped.push(track);
  }
  return mapped.sort((a, b) => Date.parse(b.observedAt) - Date.parse(a.observedAt));
}

/** Spotify throttling (429) and outages (5xx) make the service 'unavailable' for this request. */
export function isUnavailableStatus(status: number): boolean {
  return status === 429 || status >= 500;
}

// ---- Playback (Spotify Connect) ----

export type PlaybackAction = 'play' | 'pause' | 'next' | 'previous';
const PLAYBACK_ACTIONS: PlaybackAction[] = ['play', 'pause', 'next', 'previous'];

export interface PlaybackRequest { action: PlaybackAction; spotifyId?: string; deviceId?: string }

/** `{ action, spotifyId?, deviceId? }`, or null when any field is malformed. */
export function parsePlaybackRequest(input: unknown): PlaybackRequest | null {
  const body = input as { action?: unknown; spotifyId?: unknown; deviceId?: unknown } | null;
  if (!body || typeof body !== 'object' || !PLAYBACK_ACTIONS.includes(body.action as PlaybackAction)) return null;
  const action = body.action as PlaybackAction;
  if (body.spotifyId !== undefined && body.spotifyId !== null && (typeof body.spotifyId !== 'string' || !SPOTIFY_ID.test(body.spotifyId))) return null;
  if (body.deviceId !== undefined && body.deviceId !== null && (typeof body.deviceId !== 'string' || !/^[A-Za-z0-9._:-]{1,256}$/.test(body.deviceId))) return null;
  const spotifyId = typeof body.spotifyId === 'string' && action === 'play' ? body.spotifyId : undefined;
  const deviceId = typeof body.deviceId === 'string' ? body.deviceId : undefined;
  return { action, ...(spotifyId ? { spotifyId } : {}), ...(deviceId ? { deviceId } : {}) };
}

/** The Web API call for a playback request. Play without a track resumes. */
export function playbackCall(request: PlaybackRequest): { method: 'PUT' | 'POST'; url: string; body?: string } {
  const query = request.deviceId ? `?device_id=${encodeURIComponent(request.deviceId)}` : '';
  switch (request.action) {
    case 'play':
      return request.spotifyId
        ? { method: 'PUT', url: `${SPOTIFY_API}/me/player/play${query}`, body: JSON.stringify({ uris: [`spotify:track:${request.spotifyId}`] }) }
        : { method: 'PUT', url: `${SPOTIFY_API}/me/player/play${query}` };
    case 'pause':
      return { method: 'PUT', url: `${SPOTIFY_API}/me/player/pause${query}` };
    case 'next':
      return { method: 'POST', url: `${SPOTIFY_API}/me/player/next${query}` };
    case 'previous':
      return { method: 'POST', url: `${SPOTIFY_API}/me/player/previous${query}` };
  }
}

export type PlaybackOutcome = 'ok' | 'no-device' | 'premium-required' | 'failed';

/**
 * A player command's answer. 2xx is done. 404 is Spotify's `NO_ACTIVE_DEVICE` (or a
 * device id that is gone, which the person fixes the same way: open Spotify). 403 is
 * `PREMIUM_REQUIRED` or a playback restriction.
 */
export function playbackOutcome(status: number): PlaybackOutcome {
  if (status >= 200 && status < 300) return 'ok';
  if (status === 404) return 'no-device';
  if (status === 403) return 'premium-required';
  return 'failed';
}

export interface SpotifyDevice { id: string; name: string; type: string; isActive: boolean; volumePercent: number | null }

/** `GET /v1/me/player/devices`. Devices without an id cannot be targeted and are left out. */
export function mapSpotifyDevices(payload: unknown): SpotifyDevice[] {
  const devices = (payload as { devices?: unknown } | null)?.devices;
  const list = Array.isArray(devices) ? devices as Array<Record<string, unknown>> : [];
  return list.flatMap((device) => {
    const id = text(device?.id, 256);
    if (!id) return [];
    const volume = typeof device.volume_percent === 'number' && Number.isFinite(device.volume_percent) ? Math.round(device.volume_percent) : null;
    return [{ id, name: text(device.name, 200) ?? 'Spotify', type: text(device.type, 50) ?? 'Unknown', isActive: device.is_active === true, volumePercent: volume }];
  });
}
