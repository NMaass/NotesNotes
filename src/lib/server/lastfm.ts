import 'server-only';
// Last.fm credentials and linked accounts (docs/IOS_API.md, "Linked accounts"). The
// API key and shared secret are server-held; a linked session key never leaves here.
import { getCloudflareContext } from '@opennextjs/cloudflare';
import { lastfmSessionUrl, parseLastfmSession, type LastfmSessionResult } from '@/lib/music/lastfm';
import { first, run } from '@/lib/server/db';

const LASTFM_TIMEOUT_MS = 6_000;

async function secret(name: 'LASTFM_API_KEY' | 'LASTFM_SHARED_SECRET'): Promise<string | undefined> {
  try {
    const { env } = await getCloudflareContext({ async: true });
    const bound = (env as Record<string, unknown>)[name];
    if (typeof bound === 'string' && bound) return bound;
  } catch {
    // Local dev without the Cloudflare proxy falls through to process.env.
  }
  return process.env[name] || undefined;
}

export interface LastfmConfig { apiKey?: string; sharedSecret?: string }

export async function lastfmConfig(): Promise<LastfmConfig> {
  const [apiKey, sharedSecret] = await Promise.all([secret('LASTFM_API_KEY'), secret('LASTFM_SHARED_SECRET')]);
  return { apiKey, sharedSecret };
}

/** Web auth needs both the key and the shared secret. */
export function webAuthConfigured(config: LastfmConfig): config is Required<LastfmConfig> {
  return Boolean(config.apiKey && config.sharedSecret);
}

export interface LinkedLastfm { username: string; sessionKey: string; linkedAt: string }

/** The caller's linked Last.fm account, or null (also before migration 0005 has run). */
export async function linkedLastfm(profileId: string): Promise<LinkedLastfm | null> {
  try {
    const row = await first<{ username: string; session_key: string; linked_at: string }>(
      "select username, session_key, linked_at from linked_accounts where profile_id = ? and service = 'lastfm'",
      profileId,
    );
    return row ? { username: String(row.username), sessionKey: String(row.session_key), linkedAt: String(row.linked_at) } : null;
  } catch (error) {
    if (/no such table/i.test(error instanceof Error ? error.message : String(error))) return null;
    throw error;
  }
}

/** Links (or relinks) the caller's Last.fm account. Returns the stored link time. */
export async function saveLinkedLastfm(profileId: string, username: string, sessionKey: string): Promise<string> {
  const linkedAt = new Date().toISOString();
  await run(
    `insert into linked_accounts (profile_id, service, username, session_key, linked_at) values (?, 'lastfm', ?, ?, ?)
     on conflict(profile_id, service) do update set username = excluded.username, session_key = excluded.session_key, linked_at = excluded.linked_at`,
    profileId, username, sessionKey, linkedAt,
  );
  return linkedAt;
}

export async function deleteLinkedLastfm(profileId: string): Promise<void> {
  await run("delete from linked_accounts where profile_id = ? and service = 'lastfm'", profileId);
}

/** Drops a link whose session key Last.fm refused; a relink made since (a new key) stays. */
export async function deleteRevokedLastfm(profileId: string, sessionKey: string): Promise<void> {
  await run("delete from linked_accounts where profile_id = ? and service = 'lastfm' and session_key = ?", profileId, sessionKey);
}

/**
 * Trades a request token for a session (`auth.getSession`). Last.fm answers
 * errors with a non-2xx status and a JSON body, so the body is read either way.
 */
export async function exchangeLastfmToken(config: Required<LastfmConfig>, token: string): Promise<LastfmSessionResult> {
  try {
    const response = await fetch(lastfmSessionUrl(config.apiKey, config.sharedSecret, token), {
      headers: { Accept: 'application/json' },
      signal: AbortSignal.timeout(LASTFM_TIMEOUT_MS),
      cache: 'no-store',
    });
    return parseLastfmSession(await response.json().catch(() => null));
  } catch {
    return { kind: 'failed' };
  }
}
