import 'server-only';
// GET /api/now-playing: what someone is playing and recently played across their
// scrobbling accounts. Last.fm needs the server-held LASTFM_API_KEY (skipped when
// unset); a linked account's requests are signed with its session key, so a profile
// that hides recent tracks still answers. ListenBrainz needs no key. Each service
// gets 4 s; both run concurrently.
import { signedLastfmUrl, LASTFM_API } from '@/lib/music/lastfm';
import {
  currentPlay,
  mapLastfmRecentList,
  mapListenBrainzListens,
  mapListenBrainzPlayingNow,
  mergeRecentPlays,
  pickNowPlaying,
  RECENT_LIMIT,
  type NowPlayingTrack,
} from '@/lib/music/scrobbles';
import { lastfmConfig } from '@/lib/server/lastfm';

const SERVICE_TIMEOUT_MS = 4_000;

/** `errorBody`: also read a non-2xx JSON body (Last.fm answers errors that way). */
async function getJson(url: string, { errorBody = false }: { errorBody?: boolean } = {}): Promise<unknown> {
  try {
    const response = await fetch(url, { headers: { Accept: 'application/json' }, signal: AbortSignal.timeout(SERVICE_TIMEOUT_MS), cache: 'no-store' });
    if (!response.ok && !errorBody) return null;
    return await response.json();
  } catch {
    return null;
  }
}

type ServiceStatus = 'ok' | 'unavailable' | 'not-configured';

export interface NowPlayingLookup {
  /** Playing, else a play that finished within RECENT_WINDOW_MS. */
  track: NowPlayingTrack | null;
  /** Up to RECENT_LIMIT plays across services, newest first, the playing one (if any) first. */
  recent: NowPlayingTrack[];
  /** Services that were asked, and whether each answered. */
  services: Array<{ service: 'lastfm' | 'listenbrainz'; status: ServiceStatus }>;
  /** Last.fm refused the linked account's session key (access revoked): the link is stale. */
  lastfmSessionRevoked: boolean;
}

export interface LastfmAccount {
  user: string;
  /** A web-auth session key: the request is signed with it. */
  sessionKey?: string;
}

/** Last.fm's "Invalid session key - Please re-authenticate". */
const LASTFM_INVALID_SESSION = 9;

/** `before` (Unix seconds): only scrobbles that started earlier, and no playing row. */
async function fromLastfm(account: LastfmAccount, now: number, before?: number): Promise<{ tracks: NowPlayingTrack[]; status: ServiceStatus; sessionRevoked: boolean }> {
  const { apiKey, sharedSecret } = await lastfmConfig();
  if (!apiKey) return { tracks: [], status: 'not-configured', sessionRevoked: false };
  const params: Record<string, string> = { method: 'user.getrecenttracks', user: account.user, limit: String(RECENT_LIMIT), api_key: apiKey };
  if (before) params.to = String(before);
  const unsigned = `${LASTFM_API}?${new URLSearchParams({ ...params, format: 'json' }).toString()}`;
  let payload: unknown;
  let sessionRevoked = false;
  if (account.sessionKey && sharedSecret) {
    payload = await getJson(signedLastfmUrl({ ...params, sk: account.sessionKey }, sharedSecret), { errorBody: true });
    // The person revoked Resonote on last.fm: read the public profile instead.
    sessionRevoked = Number((payload as { error?: unknown } | null)?.error) === LASTFM_INVALID_SESSION;
    if (sessionRevoked) payload = await getJson(unsigned);
  } else {
    payload = await getJson(unsigned);
  }
  if (!payload || (payload as { error?: unknown }).error) return { tracks: [], status: 'unavailable', sessionRevoked };
  const tracks = mapLastfmRecentList(payload, now);
  return { tracks: before ? tracks.filter((track) => !track.isPlaying) : tracks, status: 'ok', sessionRevoked };
}

/** `before` (Unix seconds): only listens that started earlier, and no playing-now. */
async function fromListenBrainz(user: string, now: number, before?: number): Promise<{ tracks: NowPlayingTrack[]; status: 'ok' | 'unavailable' }> {
  const base = `https://api.listenbrainz.org/1/user/${encodeURIComponent(user)}`;
  if (before) {
    const listens = await getJson(`${base}/listens?count=${RECENT_LIMIT}&max_ts=${before}`);
    return listens ? { tracks: mapListenBrainzListens(listens, now), status: 'ok' } : { tracks: [], status: 'unavailable' };
  }
  // Ask for both at once: the listens are history, and the fallback when nothing is playing.
  const [playing, recent] = await Promise.all([getJson(`${base}/playing-now`), getJson(`${base}/listens?count=${RECENT_LIMIT}`)]);
  if (!playing && !recent) return { tracks: [], status: 'unavailable' };
  const live = mapListenBrainzPlayingNow(playing, now);
  return { tracks: [...(live ? [live] : []), ...mapListenBrainzListens(recent, now)], status: 'ok' };
}

/**
 * With `before` (epoch ms) it reads history instead: `recent` holds the plays that
 * started before that moment, newest first, and `track` is null. Write first, attach
 * later uses it for a note older than the newest RECENT_LIMIT plays reach.
 */
export async function lookupNowPlaying(accounts: { lastfm?: LastfmAccount; listenbrainz?: string }, options: { before?: number } = {}): Promise<NowPlayingLookup> {
  const now = Date.now();
  const before = options.before === undefined ? undefined : Math.floor(options.before / 1000);
  const [lastfm, listenbrainz] = await Promise.all([
    accounts.lastfm ? fromLastfm(accounts.lastfm, now, before) : Promise.resolve(null),
    accounts.listenbrainz ? fromListenBrainz(accounts.listenbrainz, now, before) : Promise.resolve(null),
  ]);
  const services: NowPlayingLookup['services'] = [];
  if (lastfm) services.push({ service: 'lastfm', status: lastfm.status });
  if (listenbrainz) services.push({ service: 'listenbrainz', status: listenbrainz.status });
  // `track` keeps its meaning: each service's playing row, else its newest play within the window.
  return {
    track: before ? null : pickNowPlaying([currentPlay(lastfm?.tracks, now), currentPlay(listenbrainz?.tracks, now)]),
    recent: mergeRecentPlays([lastfm?.tracks, listenbrainz?.tracks]),
    services,
    lastfmSessionRevoked: lastfm?.sessionRevoked ?? false,
  };
}
