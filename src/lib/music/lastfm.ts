// Last.fm web auth and request signing (docs/IOS_API.md, "Linked accounts"). Pure, so
// it is unit-tested directly; fetching and storage live in src/lib/server/lastfm.ts.
import { createHash } from 'node:crypto';

export const LASTFM_API = 'https://ws.audioscrobbler.com/2.0/';
/** Where Last.fm sends the person back after they approve Resonote (LastfmAuth.swift). */
export const LASTFM_CALLBACK = 'resonote://lastfm-auth';
export const LASTFM_CALLBACK_SCHEME = 'resonote';

/** Last.fm's errors for a token it will not exchange: invalid, unauthorized, expired. */
const REJECTED_TOKEN_ERRORS = new Set([4, 14, 15]);

/** Request tokens are 32 ASCII letters and digits. */
export function isValidLastfmToken(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z0-9]{32}$/.test(value);
}

/**
 * `api_sig`: the MD5 of every parameter except `format` and `callback`, sorted by
 * name and written as name then value, followed by the shared secret.
 */
export function lastfmSignature(params: Record<string, string>, secret: string): string {
  const signed = Object.keys(params)
    .filter((name) => name !== 'format' && name !== 'callback')
    .sort()
    .map((name) => `${name}${params[name]}`)
    .join('');
  return createHash('md5').update(`${signed}${secret}`, 'utf8').digest('hex');
}

/** The URL of a signed API call (JSON). */
export function signedLastfmUrl(params: Record<string, string>, secret: string): string {
  const query = new URLSearchParams({ ...params, api_sig: lastfmSignature(params, secret), format: 'json' });
  return `${LASTFM_API}?${query.toString()}`;
}

/** The page where the person approves Resonote; Last.fm then opens the callback with `?token=`. */
export function lastfmAuthUrl(apiKey: string): string {
  return `https://www.last.fm/api/auth/?api_key=${encodeURIComponent(apiKey)}&cb=${encodeURIComponent(LASTFM_CALLBACK)}`;
}

/** The signed `auth.getSession` call that trades a request token for a session. */
export function lastfmSessionUrl(apiKey: string, secret: string, token: string): string {
  return signedLastfmUrl({ api_key: apiKey, method: 'auth.getSession', token }, secret);
}

export type LastfmSessionResult =
  | { kind: 'linked'; username: string; sessionKey: string }
  | { kind: 'rejected' }
  | { kind: 'failed' };

/** Reads an `auth.getSession` answer (`{ session: { name, key } }` or `{ error, message }`). */
export function parseLastfmSession(payload: unknown): LastfmSessionResult {
  const body = payload as { session?: { name?: unknown; key?: unknown }; error?: unknown } | null;
  if (!body || typeof body !== 'object') return { kind: 'failed' };
  if (body.error !== undefined) return REJECTED_TOKEN_ERRORS.has(Number(body.error)) ? { kind: 'rejected' } : { kind: 'failed' };
  const username = typeof body.session?.name === 'string' ? body.session.name.trim() : '';
  const sessionKey = typeof body.session?.key === 'string' ? body.session.key.trim() : '';
  return username && sessionKey ? { kind: 'linked', username, sessionKey } : { kind: 'failed' };
}
