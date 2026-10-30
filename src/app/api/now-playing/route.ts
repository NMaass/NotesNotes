import { NextRequest, NextResponse } from 'next/server';
import { lookupNowPlaying, type LastfmAccount } from '@/lib/music/now-playing';
import { resolveTrack } from '@/lib/music/resolve';
import { isValidLastfmUser, isValidListenBrainzUser } from '@/lib/music/scrobbles';
import { currentUser } from '@/lib/server/auth';
import { getDb } from '@/lib/server/db';
import { deleteRevokedLastfm, linkedLastfm } from '@/lib/server/lastfm';

export const runtime = 'nodejs';
export const maxDuration = 30;

/**
 * What the caller is playing (`track`) and recently played (`recent`) across
 * their Last.fm / ListenBrainz accounts. A Last.fm account linked through web
 * auth takes the place of the `lastfm` parameter; when Last.fm refuses its
 * session key, the public profile is read instead and the stale link is dropped.
 * With `resolve=1` the /api/music/resolve result for `track` rides along, so a
 * widget needs one request. With `before=<ISO time>`, `recent` is the history
 * before that moment and `track` is null.
 */
export async function GET(request: NextRequest) {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const userId = await currentUser();
  if (!userId) return NextResponse.json({ ok: false, error: 'Sign in to see what you are playing.' }, { status: 401 });

  const params = request.nextUrl.searchParams;
  const linked = await linkedLastfm(userId).catch(() => null);
  const lastfmParam = linked ? undefined : params.get('lastfm')?.trim() || undefined;
  const listenbrainz = params.get('listenbrainz')?.trim() || undefined;
  if (!linked && !lastfmParam && !listenbrainz) {
    return NextResponse.json({ ok: false, error: 'Link a Last.fm or ListenBrainz username first.' }, { status: 400 });
  }
  if (lastfmParam && !isValidLastfmUser(lastfmParam)) return NextResponse.json({ ok: false, error: 'That is not a Last.fm username.' }, { status: 400 });
  if (listenbrainz && !isValidListenBrainzUser(listenbrainz)) return NextResponse.json({ ok: false, error: 'That is not a ListenBrainz username.' }, { status: 400 });
  const beforeParam = params.get('before')?.trim();
  const before = beforeParam ? Date.parse(beforeParam) : undefined;
  if (before !== undefined && (Number.isNaN(before) || before <= 0)) return NextResponse.json({ ok: false, error: 'before must be an ISO-8601 time.' }, { status: 400 });
  const lastfm: LastfmAccount | undefined = linked
    ? { user: linked.username, sessionKey: linked.sessionKey }
    : lastfmParam ? { user: lastfmParam } : undefined;

  try {
    const { track, recent, services, lastfmSessionRevoked } = await lookupNowPlaying({ lastfm, listenbrainz }, { before });
    // Access revoked on last.fm: forget the link, so GET /api/account/lastfm says
    // unlinked and the app offers to sign in again.
    if (lastfmSessionRevoked && linked) await deleteRevokedLastfm(userId, linked.sessionKey).catch(() => undefined);
    const resolution = track && params.get('resolve') === '1' ? await resolveTrack(track, userId) : undefined;
    return NextResponse.json(
      { ok: true, track, recent, ...(resolution ? { resolution } : {}), services },
      { headers: { 'Cache-Control': 'no-store' } },
    );
  } catch (error) {
    console.error('Resonote now-playing failed', error);
    return NextResponse.json({ ok: false, error: error instanceof Error ? error.message : 'Could not read what is playing.' }, { status: 502 });
  }
}
