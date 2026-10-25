import 'server-only';
// GET /api/now-playing: the freshest track across someone's linked scrobbling
// accounts. Last.fm needs the server-held LASTFM_API_KEY (skipped when unset);
// ListenBrainz needs no key. Each service gets 4 s; both run concurrently.
import { getCloudflareContext } from '@opennextjs/cloudflare';
import {
  mapLastfmRecentTracks,
  mapListenBrainzPlayingNow,
  mapListenBrainzRecent,
  pickNowPlaying,
  type NowPlayingTrack,
} from '@/lib/music/scrobbles';

const SERVICE_TIMEOUT_MS = 4_000;

async function lastfmKey(): Promise<string | undefined> {
  try {
    const { env } = await getCloudflareContext({ async: true });
    const bound = (env as Record<string, unknown>).LASTFM_API_KEY;
    if (typeof bound === 'string' && bound) return bound;
  } catch {
    // Local dev without the Cloudflare proxy falls through to process.env.
  }
  return process.env.LASTFM_API_KEY || undefined;
}

async function getJson(url: string, headers: Record<string, string> = {}): Promise<unknown> {
  try {
    const response = await fetch(url, { headers: { Accept: 'application/json', ...headers }, signal: AbortSignal.timeout(SERVICE_TIMEOUT_MS), cache: 'no-store' });
    if (!response.ok) return null;
    return await response.json();
  } catch {
    return null;
  }
}

export interface NowPlayingLookup {
  track: NowPlayingTrack | null;
  /** Services that were asked, and whether each answered. */
  services: Array<{ service: 'lastfm' | 'listenbrainz'; status: 'ok' | 'unavailable' | 'not-configured' }>;
}

async function fromLastfm(user: string, now: number): Promise<{ track: NowPlayingTrack | null; status: 'ok' | 'unavailable' | 'not-configured' }> {
  const key = await lastfmKey();
  if (!key) return { track: null, status: 'not-configured' };
  const payload = await getJson(
    `https://ws.audioscrobbler.com/2.0/?method=user.getrecenttracks&user=${encodeURIComponent(user)}&limit=2&format=json&api_key=${encodeURIComponent(key)}`,
  );
  if (!payload || (payload as { error?: unknown }).error) return { track: null, status: 'unavailable' };
  return { track: mapLastfmRecentTracks(payload, now), status: 'ok' };
}

async function fromListenBrainz(user: string, now: number): Promise<{ track: NowPlayingTrack | null; status: 'ok' | 'unavailable' }> {
  const base = `https://api.listenbrainz.org/1/user/${encodeURIComponent(user)}`;
  // Ask for both at once: the latest listen is the fallback when nothing is playing.
  const [playing, recent] = await Promise.all([getJson(`${base}/playing-now`), getJson(`${base}/listens?count=1`)]);
  if (!playing && !recent) return { track: null, status: 'unavailable' };
  return { track: mapListenBrainzPlayingNow(playing, now) ?? mapListenBrainzRecent(recent, now), status: 'ok' };
}

export async function lookupNowPlaying(accounts: { lastfm?: string; listenbrainz?: string }): Promise<NowPlayingLookup> {
  const now = Date.now();
  const [lastfm, listenbrainz] = await Promise.all([
    accounts.lastfm ? fromLastfm(accounts.lastfm, now) : Promise.resolve(null),
    accounts.listenbrainz ? fromListenBrainz(accounts.listenbrainz, now) : Promise.resolve(null),
  ]);
  const services: NowPlayingLookup['services'] = [];
  if (lastfm) services.push({ service: 'lastfm', status: lastfm.status });
  if (listenbrainz) services.push({ service: 'listenbrainz', status: listenbrainz.status });
  return { track: pickNowPlaying([lastfm?.track, listenbrainz?.track]), services };
}
