import 'server-only';
// Spotify credentials, the linked account and its tokens (docs/IOS_API.md, "Linked
// accounts: Spotify"). The client secret and every token stay here: the app only
// ever sees the account's id, name and product.
import { getCloudflareContext } from '@opennextjs/cloudflare';
import {
  applyTokenRefresh,
  authorizationCodeBody,
  needsRefresh,
  parseSpotifyProfile,
  parseSpotifyToken,
  refreshTokenBody,
  SPOTIFY_API,
  SPOTIFY_DEFAULT_REDIRECT_URI,
  SPOTIFY_TOKEN_URL,
  spotifyBasicAuth,
  type SpotifyProfile,
  type SpotifyTokenResult,
} from '@/lib/music/spotify';
import { first, run } from '@/lib/server/db';

const SPOTIFY_TOKEN_TIMEOUT_MS = 6_000;
const SPOTIFY_API_TIMEOUT_MS = 4_000;

type SpotifySetting = 'SPOTIFY_CLIENT_ID' | 'SPOTIFY_CLIENT_SECRET' | 'SPOTIFY_REDIRECT_URI';

async function setting(name: SpotifySetting): Promise<string | undefined> {
  try {
    const { env } = await getCloudflareContext({ async: true });
    const bound = (env as Record<string, unknown>)[name];
    if (typeof bound === 'string' && bound) return bound;
  } catch {
    // Local dev without the Cloudflare proxy falls through to process.env.
  }
  return process.env[name] || undefined;
}

export interface SpotifyConfig { clientId?: string; clientSecret?: string; redirectUri: string }

export async function spotifyConfig(): Promise<SpotifyConfig> {
  const [clientId, clientSecret, redirectUri] = await Promise.all([
    setting('SPOTIFY_CLIENT_ID'), setting('SPOTIFY_CLIENT_SECRET'), setting('SPOTIFY_REDIRECT_URI'),
  ]);
  return { clientId, clientSecret, redirectUri: redirectUri?.trim() || SPOTIFY_DEFAULT_REDIRECT_URI };
}

/** Sign-in and every token call need both the client id and the secret. */
export function spotifyConfigured(config: SpotifyConfig): config is Required<SpotifyConfig> {
  return Boolean(config.clientId && config.clientSecret);
}

export interface LinkedSpotify {
  spotifyUserId: string;
  displayName: string | null;
  product: string | null;
  scope: string;
  refreshToken: string;
  accessToken: string | null;
  accessExpiresAt: string | null;
  linkedAt: string;
}

type SpotifyRow = {
  spotify_user_id: string; display_name: string | null; product: string | null; scope: string;
  refresh_token: string; access_token: string | null; access_expires_at: string | null; linked_at: string;
};

const nullable = (value: unknown) => (value === null || value === undefined ? null : String(value));

/** The caller's linked Spotify account, or null (also before migration 0006 has run). */
export async function linkedSpotify(profileId: string): Promise<LinkedSpotify | null> {
  try {
    const row = await first<SpotifyRow>(
      `select spotify_user_id, display_name, product, scope, refresh_token, access_token, access_expires_at, linked_at
       from spotify_accounts where profile_id = ?`,
      profileId,
    );
    if (!row) return null;
    return {
      spotifyUserId: String(row.spotify_user_id),
      displayName: nullable(row.display_name),
      product: nullable(row.product),
      scope: String(row.scope),
      refreshToken: String(row.refresh_token),
      accessToken: nullable(row.access_token),
      accessExpiresAt: nullable(row.access_expires_at),
      linkedAt: String(row.linked_at),
    };
  } catch (error) {
    if (/no such table/i.test(error instanceof Error ? error.message : String(error))) return null;
    throw error;
  }
}

/** Links (or relinks) the caller's Spotify account. Returns the stored link time. */
export async function saveLinkedSpotify(
  profileId: string,
  profile: SpotifyProfile,
  tokens: { accessToken: string; expiresIn: number; refreshToken: string; scope: string },
): Promise<string> {
  const linkedAt = new Date().toISOString();
  const expiresAt = new Date(Date.now() + tokens.expiresIn * 1000).toISOString();
  await run(
    `insert into spotify_accounts (profile_id, spotify_user_id, display_name, product, scope, refresh_token, access_token, access_expires_at, linked_at)
     values (?, ?, ?, ?, ?, ?, ?, ?, ?)
     on conflict(profile_id) do update set spotify_user_id = excluded.spotify_user_id, display_name = excluded.display_name,
       product = excluded.product, scope = excluded.scope, refresh_token = excluded.refresh_token,
       access_token = excluded.access_token, access_expires_at = excluded.access_expires_at, linked_at = excluded.linked_at`,
    profileId, profile.id, profile.displayName ?? null, profile.product ?? null, tokens.scope,
    tokens.refreshToken, tokens.accessToken, expiresAt, linkedAt,
  );
  return linkedAt;
}

export async function deleteLinkedSpotify(profileId: string): Promise<void> {
  try {
    await run('delete from spotify_accounts where profile_id = ?', profileId);
  } catch (error) {
    if (!/no such table/i.test(error instanceof Error ? error.message : String(error))) throw error;
  }
}

/** Drops a link whose refresh token Spotify refused; a relink (or a rotation) made since stays. */
export async function deleteRevokedSpotify(profileId: string, refreshToken: string): Promise<void> {
  await run('delete from spotify_accounts where profile_id = ? and refresh_token = ?', profileId, refreshToken);
}

async function postToken(config: Required<SpotifyConfig>, body: URLSearchParams): Promise<SpotifyTokenResult> {
  try {
    const response = await fetch(SPOTIFY_TOKEN_URL, {
      method: 'POST',
      headers: {
        Authorization: spotifyBasicAuth(config.clientId, config.clientSecret),
        'Content-Type': 'application/x-www-form-urlencoded',
        Accept: 'application/json',
      },
      body: body.toString(),
      signal: AbortSignal.timeout(SPOTIFY_TOKEN_TIMEOUT_MS),
      cache: 'no-store',
    });
    // Spotify answers errors with a 400 and `{ error }`, so the body is read either way.
    return parseSpotifyToken(await response.json().catch(() => null));
  } catch {
    return { kind: 'failed' };
  }
}

/** Trades the callback's code (and the app's PKCE verifier) for tokens. */
export async function exchangeSpotifyCode(config: Required<SpotifyConfig>, code: string, codeVerifier: string): Promise<SpotifyTokenResult> {
  return postToken(config, authorizationCodeBody(code, config.redirectUri, codeVerifier));
}

export type SpotifyProfileResult = { kind: 'profile'; profile: SpotifyProfile } | { kind: 'forbidden' } | { kind: 'failed' };

/** `GET /v1/me`. A 403 means the account is not on the Development Mode allowlist. */
export async function fetchSpotifyProfile(accessToken: string): Promise<SpotifyProfileResult> {
  const response = await spotifyFetch(accessToken, `${SPOTIFY_API}/me`);
  if (!response) return { kind: 'failed' };
  if (response.status === 403) return { kind: 'forbidden' };
  if (!response.ok) return { kind: 'failed' };
  const profile = parseSpotifyProfile(await response.json().catch(() => null));
  return profile ? { kind: 'profile', profile } : { kind: 'failed' };
}

export type SpotifyAccess = { kind: 'ok'; accessToken: string } | { kind: 'revoked' } | { kind: 'failed' };

/** How long a refused refresh waits for a concurrent request's rotation to land before giving up the link. */
const ROTATION_SETTLE_MS = 750;

/**
 * A usable access token for the linked account, refreshed first when it is missing
 * or expires within a minute. A rotated refresh token is stored.
 *
 * Spotify refusing the refresh token (`invalid_grant`) is usually access removed at
 * spotify.com, but it is also what a request sees when a concurrent one (the
 * now-playing poll, the widget, a play) has just rotated that token. So the row is
 * read again first: a different refresh token there means someone else refreshed
 * (or relinked), and its access token is used, or the new refresh token is tried
 * once. The row is read once more after `settleMs`, in case the other request's
 * write had not landed yet. Only when the stored refresh token is still the refused
 * one is the link dropped (`revoked`), and that delete is guarded on it too.
 */
export async function spotifyAccessToken(
  profileId: string,
  linked: LinkedSpotify,
  now = Date.now(),
  options: { settleMs?: number; retried?: boolean } = {},
): Promise<SpotifyAccess> {
  if (!needsRefresh(linked, now) && linked.accessToken) return { kind: 'ok', accessToken: linked.accessToken };
  const config = await spotifyConfig();
  if (!spotifyConfigured(config)) return { kind: 'failed' };
  const result = await postToken(config, refreshTokenBody(linked.refreshToken));
  if (result.kind === 'rejected') {
    let stored = await linkedSpotify(profileId);
    if (stored?.refreshToken === linked.refreshToken) {
      await new Promise((resolve) => setTimeout(resolve, options.settleMs ?? ROTATION_SETTLE_MS));
      stored = await linkedSpotify(profileId);
    }
    if (!stored) return { kind: 'revoked' };
    if (stored.refreshToken === linked.refreshToken) {
      await deleteRevokedSpotify(profileId, linked.refreshToken).catch(() => undefined);
      return { kind: 'revoked' };
    }
    // Rotated (or relinked) by someone else: use theirs, or refresh with it once.
    if (!needsRefresh(stored, now) && stored.accessToken) return { kind: 'ok', accessToken: stored.accessToken };
    if (options.retried) return { kind: 'failed' };
    return spotifyAccessToken(profileId, stored, now, { ...options, retried: true });
  }
  if (result.kind === 'failed') return { kind: 'failed' };
  const next = applyTokenRefresh(linked, result, now);
  // Keyed on the old refresh token, so a relink made meanwhile is not overwritten.
  await run(
    'update spotify_accounts set access_token = ?, access_expires_at = ?, refresh_token = ? where profile_id = ? and refresh_token = ?',
    next.accessToken, next.accessExpiresAt, next.refreshToken, profileId, linked.refreshToken,
  ).catch((error) => console.error('Resonote Spotify token save failed', error));
  return { kind: 'ok', accessToken: next.accessToken! };
}

/** A Web API request with the access token; null when Spotify could not be reached in time. */
export async function spotifyFetch(accessToken: string, url: string, init: { method?: string; body?: string } = {}): Promise<Response | null> {
  try {
    return await fetch(url, {
      method: init.method ?? 'GET',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        Accept: 'application/json',
        ...(init.body ? { 'Content-Type': 'application/json' } : {}),
      },
      // A player command without a body still sends Content-Length: 0 (Spotify answers 411 otherwise).
      body: init.body ?? (init.method && init.method !== 'GET' ? '' : undefined),
      signal: AbortSignal.timeout(SPOTIFY_API_TIMEOUT_MS),
      cache: 'no-store',
    });
  } catch {
    return null;
  }
}

/** The caller's access token for a Spotify call: not linked (or revoked just now) is one answer. */
export async function callerSpotifyAccess(profileId: string): Promise<Exclude<SpotifyAccess, { kind: 'revoked' }> | { kind: 'not-linked' }> {
  const linked = await linkedSpotify(profileId);
  if (!linked) return { kind: 'not-linked' };
  const access = await spotifyAccessToken(profileId, linked);
  if (access.kind === 'revoked') return { kind: 'not-linked' };
  return access;
}
